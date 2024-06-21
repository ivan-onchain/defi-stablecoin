// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";
import {DeployDSC} from  "../../script/DeployDSC.s.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {ERC20Mock} from "../mocks/ERC20Mock.sol";

contract DSCEngineTest is Test {

    DecentralizedStableCoin dsc;
    DSCEngine dscEngine;
    HelperConfig helperConfig;
    address wethUsdPriceFeed;
    address wbtcUsdPriceFeed;
    address weth;
    address wbtc;
    address user;

    uint256 public constant STARTING_USER_BALANCE = 10 ether;
    uint256 public constant MIN_HEALTH_FACTOR = 1e18;
    uint256 public constant AMOUNT_COLLATERAL = 10 ether;

    function setUp() public {
        DeployDSC deployDSC = new DeployDSC();
        (dsc, dscEngine, helperConfig) = deployDSC.run();
        (
            wethUsdPriceFeed,
            wbtcUsdPriceFeed, 
            weth, 
            wbtc,
        ) = helperConfig.activeNetworkConfig();

        user = makeAddr('USER');
        ERC20Mock(weth).mint(user, STARTING_USER_BALANCE);
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
        console.log('expectedUsdValue: ',expectedUsdValue );
        console.log('usdValue: ',usdValue);
        assert(usdValue == expectedUsdValue);
        // 
        // 300000000000000
    }

    function testGetTokenAmountFromUsd() public {
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
        // ERC20Mock(weth).approve(address(dscEngine), amountCollateral);
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
        console.log('collateralValueInUsd ', collateralValueInUsd);
        assert(expectedTokenAmount == AMOUNT_COLLATERAL); 
        assert(expectedDscMinted == totalDscMinted); 
    }

}