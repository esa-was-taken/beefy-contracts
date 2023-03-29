// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface HypervisorProxy {
    event CustomDeposit(address, uint256, uint256, uint256);
    event DeltaScaleSet(uint256 _deltaScale);
    event DepositDeltaSet(uint256 _depositDelta);
    event DepositFreeOverrideToggled(address pos);
    event DepositFreeToggled();
    event DepositOverrideToggled(address pos);
    event ListAppended(address pos, address[] listed);
    event ListRemoved(address pos, address listed);
    event PositionAdded(address, uint8);
    event PriceThresholdPosSet(address pos, uint256 _priceThreshold);
    event PriceThresholdSet(uint256 _priceThreshold);
    event TwapIntervalSet(uint32 _twapInterval);
    event TwapOverrideSet(address pos, bool twapOverride, uint32 _twapInterval);
    event TwapToggled();

    function addPosition(address pos, uint8 version) external;

    function appendList(address pos, address[] memory listed) external;

    function checkPriceChange(
        address pos,
        uint32 _twapInterval,
        uint256 _priceThreshold
    ) external view returns (uint256 price);

    function customDeposit(
        address pos,
        uint256 deposit0Max,
        uint256 deposit1Max,
        uint256 maxTotalSupply
    ) external;

    function deltaScale() external view returns (uint256);

    function deposit(
        uint256 deposit0,
        uint256 deposit1,
        address to,
        address pos,
        uint256[4] memory minIn
    ) external returns (uint256 shares);

    function depositDelta() external view returns (uint256);

    function getDepositAmount(
        address pos,
        address token,
        uint256 _deposit
    ) external view returns (uint256 amountStart, uint256 amountEnd);

    function getListed(address pos, address i) external view returns (bool);

    function getSqrtTwapX96(address pos, uint32 _twapInterval)
        external
        view
        returns (uint160 sqrtPriceX96);

    function owner() external view returns (address);

    function positions(address)
        external
        view
        returns (
            uint8 version,
            bool twapOverride,
            uint32 twapInterval,
            uint256 priceThreshold,
            bool depositOverride,
            uint256 deposit0Max,
            uint256 deposit1Max,
            uint256 maxTotalSupply,
            bool freeDeposit
        );

    function priceThreshold() external view returns (uint256);

    function removeListed(address pos, address listed) external;

    function setDeltaScale(uint256 _deltaScale) external;

    function setDepositDelta(uint256 _depositDelta) external;

    function setPriceThreshold(uint256 _priceThreshold) external;

    function setPriceThresholdPos(address pos, uint256 _priceThreshold)
        external;

    function setTwapInterval(uint32 _twapInterval) external;

    function setTwapOverride(
        address pos,
        bool twapOverride,
        uint32 _twapInterval
    ) external;

    function toggleDepositFreeOverride(address pos) external;

    function toggleDepositOverride(address pos) external;

    function toggleTwap() external;

    function transferOwnership(address newOwner) external;

    function twapCheck() external view returns (bool);

    function twapInterval() external view returns (uint32);
}
