// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity ^0.8.20;

import {console} from "forge-std/console.sol";

import {DecentralizedStableCoin} from "./DecentralizedStableCoin.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { AggregatorV3Interface } from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

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

    mapping(address token => address priceFeed) private s_priceFeeds;
    mapping(address user => mapping(address token => uint256 amount)) private s_collateralDeposited;
    mapping(address user => uint256 amountDscMinted) private s_DSCMinted;
    address[] private s_collateralTokens;

    
     /////////////////
    /// Events /// 
    ///////////////// 
    event CollateralDeposited(address indexed user, address indexed collateralToken, uint256 indexed collateralAmount);
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
        s_collateralDeposited[msg.sender][collateralToken] = collateralAmount;
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
        return _calculateHealthFactor(totalDscMinted, collateralValueInUsd);
    }

 

    function _calculateHealthFactor(
        uint256 totalDscMinted,
        uint256 collateralValueInUsd
    )
        internal
        pure
        returns (uint256)
    {
        if (totalDscMinted == 0) return type(uint256).max;
        uint256 collateralAdjustedForThreshold = (collateralValueInUsd * LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION;
        return (collateralAdjustedForThreshold * PRECISION) / totalDscMinted;
    }

    function _revertIfHealthFactorIsBroken(address user) internal view {
        uint256 userHealthFactor = _healthFactor(user);
        if (userHealthFactor < MIN_HEALTH_FACTOR) {
            revert DSCEngine__BreaksHealthFactor(userHealthFactor);
        }
    }

    /////////////////////////////////////////////////////////
    // External & Public View & Pure Functions ////////////
    /////////////////////////////////////////////////////////

    function getAccountCollateralValue(address user) public view returns (uint256 totalCollateralValueInUsd) {
        for (uint256 index = 0; index < s_collateralTokens.length; index++) {
            address token = s_collateralTokens[index];
            uint256 amount = s_collateralDeposited[user][token];
            totalCollateralValueInUsd += getUsdValue(token, amount);
        }
        return totalCollateralValueInUsd;
    }

       function getUsdValue(address token, uint256 amount) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (, int256 price,,,) = priceFeed.latestRoundData();
        // 1 ETH = 1000 USD
        // The returned value from Chainlink will be 1000 * 1e8. It is got it from Chainlink data-feed/prices
        // Most USD pairs have 8 decimals, so we will just pretend they all do
        // We want to have everything in terms of WEI, so we add 10 zeros at the end
        console.log('price: ', uint256(price));
        return ((uint256(price) * ADDITIONAL_FEED_PRECISION) * amount) / PRECISION;
    }
}