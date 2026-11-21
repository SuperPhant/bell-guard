// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {ISystemContract} from "reactive-lib-omni/interfaces/ISystemContract.sol";

/// @notice Stand-in for Reactive Network's system contract (0x8888…8888) in local tests: records subscriptions
///         and callback requests instead of acting on them.
contract MockSystem {
    struct Subscription {
        uint256 chainId;
        address target;
        uint256 topic0;
        uint256 topic1;
        uint256 topic2;
        uint256 topic3;
        bool active;
    }

    Subscription[] public subscriptions;
    ISystemContract.CallbackConfiguration_V_1_0[] internal _callbacks;

    function subscribe(uint256 chainId, address target, uint256 t0, uint256 t1, uint256 t2, uint256 t3) external {
        subscriptions.push(Subscription(chainId, target, t0, t1, t2, t3, true));
    }

    function unsubscribe(uint256 chainId, address target, uint256 t0, uint256 t1, uint256 t2, uint256 t3) external {
        for (uint256 i; i < subscriptions.length; ++i) {
            Subscription storage s = subscriptions[i];
            if (
                s.active && s.chainId == chainId && s.target == target && s.topic0 == t0 && s.topic1 == t1
                    && s.topic2 == t2 && s.topic3 == t3
            ) s.active = false;
        }
    }

    function requestCallbackV_1_0(ISystemContract.CallbackConfiguration_V_1_0 memory config) external {
        _callbacks.push(config);
    }

    function debt(address) external pure returns (uint256) {
        return 0;
    }

    function subscriptionCount() external view returns (uint256) {
        return subscriptions.length;
    }

    function callbackCount() external view returns (uint256) {
        return _callbacks.length;
    }

    function callbackAt(uint256 i) external view returns (ISystemContract.CallbackConfiguration_V_1_0 memory) {
        return _callbacks[i];
    }

    receive() external payable {}
}
