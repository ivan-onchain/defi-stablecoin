// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity ^0.8.20;

import {Script} from "forge-std/Script.sol";
import {DecentralizedStableCoin} from "../src/DecentralizedStableCoin.sol";

contract DeployDecentralizedStableCoin is Script {
    function run() public {
        vm.startBroadcast();
        new DecentralizedStableCoin();
        vm.stopBroadcast();
    }
}