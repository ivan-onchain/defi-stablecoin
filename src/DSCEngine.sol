// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity ^0.8.20;

import {console} from "forge-std/console.sol";

import {DecentralizedStableCoin} from "./DecentralizedStableCoin.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { AggregatorV3Interface } from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import {OracleLib} from "./lib/OracleLib.sol";

contract DSCEngine is ReentrancyGuard {
    /////////////////
    /// Errors  /// 
    ///////////////// 
    error DSCEngine__NeedsMoreThanZero();
    error DSCEngine__TokenAddressesLengthNotEqualToPriceFeedAddressLength();
    error DSCEngine__CollateralAddressIsNotWhiteListed();
    error DSCEngine__TransferFailed();
    error DSCEngine__BreaksHealthFactor(uint256 healthFactorValue);
    error DSCEngine__MintFailed();
    error DSCEngine__HealthFactorOk();
    error DSCEngine__HealthFactorNotImproved();

    /////////////////
    /// Types  /// 
    ///////////////// 

    using OracleLib for AggregatorV3Interface;

    /////////////////
    /// State variables /// 
    ///////////////// 

    DecentralizedStableCoin immutable i_dsc;

    uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10;
    uint256 private constant FEED_PRECISION = 1e8;
    uint256 private constant PRECISION = 1e18;
    uint256 private constant LIQUIDATION_THRESHOLD = 50; // This means 200% overcollaterazed!!
    uint256 private constant LIQUIDATION_PRECISION = 100;
    uint256 private constant MIN_HEALTH_FACTOR = 1e18;
    uint256 private constant LIQUIDATION_BONUS = 10;

    mapping(address token => address priceFeed) private s_priceFeeds;
    mapping(address user => mapping(address token => uint256 amount)) private s_collateralDeposited;
    mapping(address user => uint256 amountDscMinted) private s_DSCMinted;
    address[] private s_collateralTokens;
     /////////////////
    /// Events /// 
    ///////////////// 
    event CollateralDeposited(address indexed user, address indexed collateralToken, uint256 indexed collateralAmount);
    event CollateralRedeemed(address indexed redeemFrom, address indexed redeemTo, address token, uint256 amount); // if
    /////////////////
    /// Modifiers /// 
    ///////////////// 
    modifier moreThanZero(uint256 amount) {
        if (amount == 0) {
            revert DSCEngine__NeedsMoreThanZero();
        }
        _;
    }
    modifier onlyCollateralAllowed(address collateralAddress) {
        if(s_priceFeeds[collateralAddress] == address(0)){
            revert DSCEngine__CollateralAddressIsNotWhiteListed();
        }
        _;
    }
    ///////////////////////////
    /// Functions /// 
    ////////////////////////// 

    constructor(address[] memory tokenAddresses, address[] memory priceFeedAddresses, address dscAddress ) {
        if (tokenAddresses.length != priceFeedAddresses.length) {
            revert DSCEngine__TokenAddressesLengthNotEqualToPriceFeedAddressLength();
        }
        for(uint256 i = 0; i < tokenAddresses.length; i++ ){
            s_priceFeeds[tokenAddresses[i]] = priceFeedAddresses[i];
            s_collateralTokens.push(tokenAddresses[i]);
        }
        i_dsc = DecentralizedStableCoin(dscAddress);
    } 
    ///////////////////////////
    /// External functions /// 
    ////////////////////////// 
    /**
     * @notice it follows CEI structure - Check, Effects, Interactions
     * @param collateralToken token address of the collateral
     * @param collateralAmount amount of the collateral
     */
    function depositCollateral(address collateralToken, uint256 collateralAmount) public
        moreThanZero(collateralAmount) 
        onlyCollateralAllowed(collateralToken)
        nonReentrant {
        s_collateralDeposited[msg.sender][collateralToken] += collateralAmount;
        emit CollateralDeposited(msg.sender, collateralToken, collateralAmount);
        bool success = IERC20(collateralToken).transferFrom(msg.sender, address(this), collateralAmount); 
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
    }

    function mintDSC(uint256 amountDscToMint) public moreThanZero(amountDscToMint) nonReentrant {
        s_DSCMinted[msg.sender] += amountDscToMint;
        _revertIfHealthFactorIsBroken(msg.sender);
        bool isMinted = i_dsc.mint(msg.sender, amountDscToMint);
        if (!isMinted) {
            revert DSCEngine__MintFailed();
        }
    }

    function depositCollateralAndMintDSC(
        address tokenCollateralAddress, 
        uint256 amountCollateral,
        uint256 amountDSCToMint
    ) external {
        depositCollateral(tokenCollateralAddress, amountCollateral);
        mintDSC(amountDSCToMint);
    }

    function redeemCollateral(
        address collateralToken,
        uint256 collateralAmount
        ) public moreThanZero(collateralAmount) onlyCollateralAllowed(collateralToken) nonReentrant {
        _redeemCollateral(collateralToken, collateralAmount, msg.sender, msg.sender);
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    function burnDsc(uint256 amount) public moreThanZero(amount) nonReentrant {
        _burnDsc(amount, msg.sender, msg.sender);
        _revertIfHealthFactorIsBroken(msg.sender); // I don't think this would ever hit..
    }

    function redeemCollateralForDsc(
        address collateralToken, 
        uint256 collateralAmount,
        uint256 dscAmoount
    ) external {
        burnDsc(dscAmoount);
        redeemCollateral(collateralToken, collateralAmount);
    }

        /*
     * @param collateral: The ERC20 token address of the collateral you're using to make the protocol solvent again.
     * This is collateral that you're going to take from the user who is insolvent.
     * In return, you have to burn your DSC to pay off their debt, but you don't pay off your own.
     * @param user: The user who is insolvent. They have to have a _healthFactor below MIN_HEALTH_FACTOR
     * @param debtToCover: The amount of DSC you want to burn to cover the user's debt.
     *
     * @notice: You can partially liquidate a user.
     * @notice: You will get a 10% LIQUIDATION_BONUS for taking the users funds.
    * @notice: This function working assumes that the protocol will be roughly 150% overcollateralized in order for this
    to work.
    * @notice: A known bug would be if the protocol was only 100% collateralized, we wouldn't be able to liquidate
    anyone.
     * For example, if the price of the collateral plummeted before anyone could be liquidated.
     */
    function liquidate(
        address collateral,
        address user,
        uint256 debtToCover
    )
        external
        moreThanZero(debtToCover)
        nonReentrant
    {
        uint256 startingUserHealthFactor = _healthFactor(user);
        
        if (startingUserHealthFactor >= MIN_HEALTH_FACTOR) {
            revert DSCEngine__HealthFactorOk();
        }
        // If covering 100 DSC, we need to $100 of collateral
        console.log('debtToCover: ', debtToCover);
        
        uint256 tokenAmountFromDebtCovered = getTokenAmountFromUsd(collateral, debtToCover);
        console.log('tokenAmountFromDebtCovered: ', tokenAmountFromDebtCovered);
        // 1000000000000000000
        // 100000000000000000
        // And give them a 10% bonus
        // So we are giving the liquidator $110 of WETH for 100 DSC
        // We should implement a feature to liquidate in the event the protocol is insolvent
        // And sweep extra amounts into a treasury
        uint256 bonusCollateral = (tokenAmountFromDebtCovered * LIQUIDATION_BONUS) / LIQUIDATION_PRECISION;
        // Burn DSC equal to debtToCover
        // Figure out how much collateral to recover based on how much burnt
        _redeemCollateral(collateral, tokenAmountFromDebtCovered + bonusCollateral, user, msg.sender);
        _burnDsc(debtToCover, user, msg.sender);
        
        uint256 endingUserHealthFactor = _healthFactor(user);
        // This conditional should never hit, but just in case
        if (endingUserHealthFactor <= startingUserHealthFactor) {
            revert DSCEngine__HealthFactorNotImproved();
        }
        _revertIfHealthFactorIsBroken(user);
    }

        //////////////////////////////
    // Private & Internal View & Pure Functions
    //////////////////////////////

    function _getAccountInformation(address user)
        private
        view
        returns (uint256 totalDscMinted, uint256 collateralValueInUsd)
    {
        totalDscMinted = s_DSCMinted[user];
        collateralValueInUsd = getAccountCollateralValue(user);
    }

    function _healthFactor(address user) private view returns (uint256) {
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = _getAccountInformation(user);
        console.log('totalDscMinted: ', totalDscMinted);
        console.log('collateralValueInUsd: ', collateralValueInUsd/1e18);
        
        return _calculateHealthFactor(totalDscMinted, collateralValueInUsd);
    }

    function _calculateHealthFactor(
        uint256 totalDscMinted,
        uint256 collateralValueInUsd
    )
        internal
        view
        returns (uint256)
    {
        if (totalDscMinted == 0 && collateralValueInUsd > 0) return type(uint256).max;
        if (collateralValueInUsd == 0) return type(uint256).min;
        //Example: $2000 ETH(CollateralValueInUsd) | $1000 DSC
        // collateralAdjustedForThreshold = 2000 * (50(threshold) / 100 (liquidacion precision)) = 2000 * (1/2) = 1000
        // HealthFactor = collateralAdjustedForThreshold * 1e18 / 2000(dsc) = 1000/1000 * 1e18 = 1 * 1e18
        // A healthFactor > than 1e18 is a good heathFactor in this protocol. 
        // Example of bad heathFactor: $1999 ETH | $1000 DSC.
        // collateralAdjustedForThreshold = 1999 * (50(threshold) / 100 (liquidacion precision)) = 1999 * (1/2) = 999.5
        // HealthFactor = collateralAdjustedForThreshold * 1e18 / 1000 = 999/1000 * 1e18 = 0.999 * 1e18 < 1e18.
        
        uint256 collateralAdjustedForThreshold = (collateralValueInUsd * LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION;
        return (collateralAdjustedForThreshold * PRECISION) / totalDscMinted;
        // return (collateralAdjustedForThreshold) / totalDscMinted;
    }

    function _revertIfHealthFactorIsBroken(address user) internal view {
        uint256 userHealthFactor = _healthFactor(user);
        // check comments in _calculateHealthFactor function to further explanation.
        if (userHealthFactor < MIN_HEALTH_FACTOR) { 
            revert DSCEngine__BreaksHealthFactor(userHealthFactor);
        }
    }

    function _redeemCollateral(
        address tokenCollateralAddress,
        uint256 amountCollateral,
        address from,
        address to
    )
        private
    {   
        s_collateralDeposited[from][tokenCollateralAddress] -= amountCollateral;
        emit CollateralRedeemed(from, to, tokenCollateralAddress, amountCollateral);
        bool success = IERC20(tokenCollateralAddress).transfer(to, amountCollateral);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
    }

    /*
     * @notice careful! You'll burn your DSC here! Make sure you want to do this...
     * @dev you might want to use this if you're nervous you might get liquidated and want to just burn
     * you DSC but keep your collateral in.
     */
    function _burnDsc(uint256 amountDscToBurn, address onBehalfOf, address dscFrom) private {
        s_DSCMinted[onBehalfOf] -= amountDscToBurn;

        bool success = i_dsc.transferFrom(dscFrom, address(this), amountDscToBurn);
        // This conditional is hypothetically unreachable
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
        i_dsc.burn(amountDscToBurn);
    }

    /////////////////////////////////////////////////////////
    // External & Public View & Pure Functions ////////////
    /////////////////////////////////////////////////////////

    function getAccountInformation(address user) external view returns (uint256 totalDscMinted, uint256 collateralValueInUsd){
        (totalDscMinted, collateralValueInUsd) = _getAccountInformation(user);
    }

    function getAccountCollateralValue(address user) public view returns (uint256 totalCollateralValueInUsd) {
        for (uint256 index = 0; index < s_collateralTokens.length; index++) {
            address token = s_collateralTokens[index];
            uint256 amount = s_collateralDeposited[user][token];
            totalCollateralValueInUsd += getUsdValue(token, amount);
        }
        return totalCollateralValueInUsd;
    }

    function getTokenAmountFromUsd(address token, uint256 usdAmountInWei) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (, int256 price,,,) = priceFeed.staleCheckLatestRoundData();
        // $100e18 USD Debt
        // 1 ETH = 2000 USD
        // The returned value from Chainlink will be 2000 * 1e8
        // Most USD pairs have 8 decimals, so we will just pretend they all do
        return ((usdAmountInWei * PRECISION) / (uint256(price) * ADDITIONAL_FEED_PRECISION));
    }

    function getUsdValue(address token, uint256 amount) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (, int256 price,,,) = priceFeed.staleCheckLatestRoundData();
        
        // 1 ETH = 1000 USD
        // The returned value from Chainlink will be 1000 * 1e8. It is got it from Chainlink data-feed/prices
        // Most USD pairs have 8 decimals, so we will just pretend they all do
        // We want to have everything in terms of WEI, so we add 10 zeros at the end
        return ((uint256(price) * ADDITIONAL_FEED_PRECISION) * amount) / PRECISION;
    }

    function calculateHealthFactor( uint256 totalDscMinted,
        uint256 collateralValueInUsd) public view
        returns (uint256){
            return _calculateHealthFactor(totalDscMinted,  collateralValueInUsd);
    }

    function getCollateralTokens() public view returns (address[] memory){
        return s_collateralTokens;
    }

    function getCollateralTokenPriceFeed(address collateralToken) public view returns (address priceFeed){
        return s_priceFeeds[collateralToken];
    }

    function getCollateralBalanceOfUser(address collateralToken, address user) public view returns (uint256) {
        return s_collateralDeposited[user][collateralToken];
    }

    function getMinHealthFactor() public pure returns (uint256){
        return MIN_HEALTH_FACTOR;
    }

    function getHealthFactor(address user) external view returns (uint256) {
     return _healthFactor(user);
    }

    function getAdditionalFeedPrecision() external pure returns (uint256) {
        return ADDITIONAL_FEED_PRECISION;
    }

    function getLiquidationBonus() external pure returns (uint256) {
        return LIQUIDATION_BONUS;
    }

    function getLiquidationThreshold() external pure returns (uint256) {
        return LIQUIDATION_THRESHOLD;
    }

    function getPrecision() external pure returns (uint256) {
        return PRECISION;
    }

    function getDsc() external view returns (address) {
        return address(i_dsc);
    }
}