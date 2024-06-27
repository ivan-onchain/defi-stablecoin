// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";
import {DeployDSC} from  "../../script/DeployDSC.s.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {ERC20Mock} from "../mocks/ERC20Mock.sol";
import {MockV3Aggregator} from "../mocks/MockV3Aggregator.sol";

contract DSCEngineTest is Test {

    DecentralizedStableCoin dsc;
    DSCEngine dscEngine;
    HelperConfig helperConfig;
    address wethUsdPriceFeed;
    address wbtcUsdPriceFeed;
    address weth;
    address wbtc;
    uint256 deployerKey;
    address user;
    address liquidator;

    uint256 public constant STARTING_USER_BALANCE = 10 ether;
    uint256 public constant MIN_HEALTH_FACTOR = 1e18;
    uint256 public constant AMOUNT_COLLATERAL = 10 ether;
    uint256 public constant AMOUNT_COLLATERAL_TO_REDEEM = 1 ether;
    uint256 public constant AMOUNT_DSC_TO_MINT = 100 ether;
    uint256 public constant AMOUNT_DSC_TO_LIQUIDATE = 100 ether;
    int256 public constant UPDATE_WETHUSD_ANSWER = 18e8;

    function setUp() public {
        DeployDSC deployDSC = new DeployDSC();
        (dsc, dscEngine, helperConfig) = deployDSC.run();
        (
            wethUsdPriceFeed,
            wbtcUsdPriceFeed, 
            weth, 
            wbtc,
            deployerKey
        ) = helperConfig.activeNetworkConfig();

        user = makeAddr('USER');
        ERC20Mock(weth).mint(user, STARTING_USER_BALANCE);
        liquidator = makeAddr('LIQUIDATOR');
        vm.startPrank(address(dscEngine));
        dsc.mint(liquidator, AMOUNT_DSC_TO_LIQUIDATE);
        vm.stopPrank();
    }

    ///////////////////////////
    ///// Contructor Tests ////
    ///////////////////////////
    address[] public tokenAddresses;
    address[] public priceFeedAddresses;
    function testRevertsIfTokenLengthDoesMathPriceFeedLenth() public {
       tokenAddresses.push(weth);
       tokenAddresses.push(wbtc);
       priceFeedAddresses.push(wethUsdPriceFeed);
       vm.expectRevert(DSCEngine.DSCEngine__TokenAddressesLengthNotEqualToPriceFeedAddressLength.selector);
       new DSCEngine(tokenAddresses, priceFeedAddresses, address(dsc));
    }


    function testGetUsdValue() public view{
        // dscEngine.deposiCollateral(weth, )
        uint256 amount = 15;
        uint256 expectedUsdValue = 2000 * amount;
        uint256 usdValue = dscEngine.getUsdValue(weth, amount );
        assert(usdValue == expectedUsdValue);
        // 
        // 300000000000000
    }

    function testGetTokenAmountFromUsd() public view {
        uint256 usdAmount = 100 ether;
        uint256 expectedWeth = 0.05 ether;
        uint256 actualWeth = dscEngine.getTokenAmountFromUsd(weth, usdAmount);
        assert(actualWeth == expectedWeth);
    }

    //////////////////////////// 
    ////////Deposit tests///////
    //////////////////////////// 
    function testRevertsWithUnapprovalCollateral() public{
        ERC20Mock unapprovalCollateral = new ERC20Mock('UnapprovalCollateral', 'UAC', user, AMOUNT_COLLATERAL);
        vm.expectRevert(DSCEngine.DSCEngine__CollateralAddressIsNotWhiteListed.selector);
        vm.startPrank(user);
        dscEngine.depositCollateral(address(unapprovalCollateral), 10 ether);
        vm.stopPrank();
    }

    function testRevertsIfCollateralZero() public {
        vm.startPrank(user);
        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        dscEngine.depositCollateral(weth, 0);
        vm.stopPrank();
    }

    modifier deposiCollateral {
        vm.startPrank(user);
        ERC20Mock(weth).approve(address(dscEngine), AMOUNT_COLLATERAL);
        dscEngine.depositCollateral(weth, AMOUNT_COLLATERAL);
        vm.stopPrank();
        _;
    }

    function testCanDepositAndCheckAcountInfo() public deposiCollateral {
        ( uint256 totalDscMinted, uint256 collateralValueInUsd) = dscEngine.getAccountInformation(user);
        uint256 expectedTokenAmount = dscEngine.getTokenAmountFromUsd(weth,collateralValueInUsd);
        uint256 expectedDscMinted = 0;
        assert(expectedTokenAmount == AMOUNT_COLLATERAL); 
        assert(expectedDscMinted == totalDscMinted); 
    }

     function testCanDepositAndCheckDscEngineBalance() public deposiCollateral {
        uint256 expecteDscEngineBalance = AMOUNT_COLLATERAL;
        uint256 dscEngineBalance = ERC20Mock(weth).balanceOf(address(dscEngine));
        assert(expecteDscEngineBalance == dscEngineBalance);
    }

    //////////////////////////// 
    ////////MintDsc tests///////
    //////////////////////////// 

    function testRevertsMintDscIfHealthFactorIsBroken() public  {
        uint256 currentHealthFactor = dscEngine.getHealthFactor(user);
        vm.expectRevert(
               abi.encodeWithSelector(
                DSCEngine.DSCEngine__BreaksHealthFactor.selector,
                currentHealthFactor
            )
            );
        dscEngine.mintDSC(AMOUNT_DSC_TO_MINT);
    }

      modifier mintDsc {
         vm.startPrank(user);
        dscEngine.mintDSC(AMOUNT_DSC_TO_MINT);
        vm.stopPrank();
        _;
    }

    function testShouldMintDscAndCheckNewUserBalance() public deposiCollateral mintDsc{
        uint256 expectedDscBalance = AMOUNT_DSC_TO_MINT;
        uint256 newDscUserBalance = dsc.balanceOf(user);
        assert(expectedDscBalance == newDscUserBalance);
    }

    //////////////////////////// 
    ////////Redeem tests///////
    //////////////////////////// 

    function testRevertsIfRedeemBreaksHealthFactor() public deposiCollateral mintDsc {
        vm.expectRevert(
               abi.encodeWithSelector(
                DSCEngine.DSCEngine__BreaksHealthFactor.selector,
                0
            )
            );
        vm.startPrank(user);
        dscEngine.redeemCollateral(weth, AMOUNT_COLLATERAL);
        vm.stopPrank();
    }

    function testShouldRedeemAndCheckNewAccountInfo() public deposiCollateral mintDsc{
        vm.startPrank(user);
        dscEngine.redeemCollateral(weth, AMOUNT_COLLATERAL_TO_REDEEM);
        vm.stopPrank();
        ( uint256 totalDscMinted, uint256 collateralValueInUsd) = dscEngine.getAccountInformation(user);
        uint256 tokenAmount = dscEngine.getTokenAmountFromUsd(weth,collateralValueInUsd);
        uint256 expectedTokenAmount = AMOUNT_COLLATERAL - AMOUNT_COLLATERAL_TO_REDEEM;
        assert(expectedTokenAmount == tokenAmount);
        assert(totalDscMinted == AMOUNT_DSC_TO_MINT);
    }

     //////////////////////////// 
    ////////BurnDsc tests///////
    //////////////////////////// 
    function testShouldBurnDscAndCheckAccountInfo() public deposiCollateral mintDsc {

        vm.startPrank(user);
        dsc.approve(address(dscEngine), AMOUNT_DSC_TO_MINT);
        dscEngine.burnDsc(AMOUNT_DSC_TO_MINT);
        vm.stopPrank();
        ( uint256 totalDscMinted, ) = dscEngine.getAccountInformation(user);
        assert(totalDscMinted == 0);
    }

    //////////////////////////// 
    ////////Liquidate tests///////
    //////////////////////////// 

    function testRevertsIfHealthFactorIsOk() public deposiCollateral mintDsc{
        vm.expectRevert(DSCEngine.DSCEngine__HealthFactorOk.selector);
        vm.startPrank(liquidator);
        dscEngine.liquidate(weth, user, AMOUNT_DSC_TO_LIQUIDATE);
        vm.stopPrank();
    }
    

    function testShouldLiquidateAndCheckLiquidatorAndAccountBalances() public deposiCollateral mintDsc{
        ( uint256 totalDscMinted, uint256 collateralValueInUsd) = dscEngine.getAccountInformation(user);
        console.log('totalDscMinted: ', totalDscMinted);
        console.log('collateralValueInUsd: ', collateralValueInUsd);
        console.log('initial.healthFactor(user): ', dscEngine.getHealthFactor(user));
            // 100000000000000000000
            // 500000000000000000
        MockV3Aggregator(wethUsdPriceFeed).updateAnswer(UPDATE_WETHUSD_ANSWER);
        
        vm.startPrank(liquidator);
        dsc.approve(address(dscEngine), AMOUNT_DSC_TO_MINT);
        dscEngine.liquidate(weth, user, AMOUNT_DSC_TO_MINT);
        vm.stopPrank();
    }
}