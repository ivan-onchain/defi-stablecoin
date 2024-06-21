// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity ^0.8.20;

import {Script} from "forge-std/Script.sol";
import {MockV3Aggregator} from "../test/mocks/MockV3Aggregator.sol";
import {ERC20Mock} from "../test/mocks//ERC20Mock.sol";

contract HelperConfig is Script{

    uint8 private constant WETHUSD_DECIMALS = 8;
    int256 private constant INITIAL_WETHUSD_ANSWER = 2000e8;
    int256 private constant INITIAL_WBTCUSD_ANSWER = 1000e8;

    struct NetworkConfig {
        address wethUsdPriceFeed;
        address wbtcUsdPriceFeed;
        address weth;
        address wbtc;
        uint256 deployerKey;
    }

    NetworkConfig public activeNetworkConfig;
    MockV3Aggregator wethUsdPriceFeedMock;
    MockV3Aggregator wbtcUsdPriceFeedMock;
    ERC20Mock wethMock;
    ERC20Mock wbtcMock;

    constructor() {
        if (block.chainid == 11155111) {
            activeNetworkConfig = getSepoliaEthConfig();
        }else{
            activeNetworkConfig = getorCreateAnvilEthConfig();
        }
    }

    function getSepoliaEthConfig() public  view returns (NetworkConfig memory networkConfig) {
        return NetworkConfig({
            wethUsdPriceFeed: 0x694AA1769357215DE4FAC081bf1f309aDC325306, // ETH / USD
            wbtcUsdPriceFeed: 0x1b44F3514812d835EB1BDB0acB33d3fA3351Ee43,
            weth: 0xdd13E55209Fd76AfE204dBda4007C227904f0a81,
            wbtc: 0x8f3Cf7ad23Cd3CaDbD9735AFf958023239c6A063,
            deployerKey: vm.envUint("PRIVATE_KEY")
        }); 
    }
    
    function getorCreateAnvilEthConfig() public returns (NetworkConfig memory networkConfig) {
     
        vm.startBroadcast();

        wethUsdPriceFeedMock = new MockV3Aggregator(WETHUSD_DECIMALS,INITIAL_WETHUSD_ANSWER);
        wbtcUsdPriceFeedMock = new MockV3Aggregator(WETHUSD_DECIMALS,INITIAL_WBTCUSD_ANSWER);
        wethMock = new ERC20Mock(
            'Wrapper Ethereum', 
            'WETH', 
            msg.sender,
            1000e8
            );
        wbtcMock = new ERC20Mock(
            'Wrapper Bitcoin', 
            'WBTC', 
            msg.sender,
            1000e8
            );

        vm.stopBroadcast();

        return NetworkConfig({
            wethUsdPriceFeed: address(wethUsdPriceFeedMock),
            wbtcUsdPriceFeed: address(wbtcUsdPriceFeedMock),
            weth: address(wethMock),
            wbtc: address(wbtcMock),
            deployerKey: 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
        });
    }
}