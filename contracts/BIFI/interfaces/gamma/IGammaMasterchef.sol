// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface IGammaMasterchef {
     struct PoolInfo {
        uint128 accSushiPerShare;
        uint64 lastRewardTime;
        uint64 allocPoint;
        address[] rewarders;
    }

    event Deposit(
        address indexed user,
        uint256 indexed pid,
        uint256 amount,
        address indexed to
    );
    event EmergencyWithdraw(
        address indexed user,
        uint256 indexed pid,
        uint256 amount,
        address indexed to
    );
    event Harvest(address indexed user, uint256 indexed pid, uint256 amount);
    event LogPoolAddition(
        uint256 indexed pid,
        uint256 allocPoint,
        address indexed lpToken
    );
    event LogRewarderAdded(uint256 indexed pid, address indexed rewarder);
    event LogSetPool(uint256 indexed pid, uint256 allocPoint);
    event LogSushiPerSecond(uint256 sushiPerSecond);
    event LogUpdatePool(
        uint256 indexed pid,
        uint64 lastRewardTime,
        uint256 lpSupply,
        uint256 accSushiPerShare
    );
    event OwnershipTransferred(
        address indexed previousOwner,
        address indexed newOwner
    );
    event Withdraw(
        address indexed user,
        uint256 indexed pid,
        uint256 amount,
        address indexed to
    );

    function SUSHI() external view returns (address);

    function add(uint256 allocPoint, address _lpToken) external;

    function addRewarder(uint256 _pid, address _rewarder) external;

    function batch(bytes[] memory calls, bool revertOnFail)
        external
        payable
        returns (bool[] memory successes, bytes[] memory results);

    function claimOwnership() external;

    function deposit(
        uint256 pid,
        uint256 amount,
        address to
    ) external;

    function emergencyWithdraw(uint256 pid, address to) external;

    function getRewarder(uint256 _pid, uint256 _rid)
        external
        view
        returns (address);

    function harvest(uint256 pid, address to) external;

    function lpToken(uint256) external view returns (address);

    function massUpdatePools(uint256[] memory pids) external;

    function owner() external view returns (address);

    function pendingOwner() external view returns (address);

    function pendingSushi(uint256 _pid, address _user)
        external
        view
        returns (uint256 pending);

    function permitToken(
        address token,
        address from,
        address to,
        uint256 amount,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external;

    function poolInfo(uint256)
        external
        view
        returns (
            uint128 accSushiPerShare,
            uint64 lastRewardTime,
            uint64 allocPoint
        );

    function poolLength() external view returns (uint256 pools);

    function reclaimTokens(
        uint256 _pid,
        uint256 _rid,
        uint256 amount,
        address to
    ) external;

    function set(uint256 _pid, uint256 _allocPoint) external;

    function setSushiPerSecond(uint256 _sushiPerSecond) external;

    function sushiPerSecond() external view returns (uint256);

    function totalAllocPoint() external view returns (uint256);

    function transferOwnership(
        address newOwner,
        bool direct,
        bool renounce
    ) external;

    function updatePool(uint256 pid)
        external
        returns (PoolInfo memory pool);

    function userInfo(uint256, address)
        external
        view
        returns (uint256 amount, int256 rewardDebt);

    function withdraw(
        uint256 pid,
        uint256 amount,
        address to
    ) external;

    function withdrawAndHarvest(
        uint256 pid,
        uint256 amount,
        address to
    ) external;
}