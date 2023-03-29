// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin-4/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin-4/contracts/token/ERC20/utils/SafeERC20.sol";

import "../../interfaces/common/ISolidlyRouter.sol";
import "../../interfaces/common/ISolidlyPair.sol";
import "../../interfaces/common/IUniswapRouterV3.sol";
import "../../interfaces/common/IERC20Extended.sol";
import "../Common/StratFeeManagerInitializable.sol";
import "../../utils/UniV3Actions.sol";

import "../../interfaces/quick/IDragonsLair.sol";
import "../../interfaces/gamma/IGammaMasterchef.sol";
import "../../interfaces/gamma/IGammaRewarder.sol";
import "../../interfaces/gamma/IHypervisor.sol";
import "../../interfaces/gamma/IHypervisorProxy.sol";


/*
    Deposit
        Want LP deposited into vault
        vault deposits into strategy
        strategy deposits want LP into chef
    Harvest
        Get rewards from chef
        Swap rewards to native
        Take fee
        Swap native to lpToken0 and lpToken1 according to ratio in LP
        Deposit lpToken0 and lpToken1 to get want LP
        Deposit want LP into chef 
    Withdraw
        Harvest
        Withdraw want LP from chef
*/

contract StrategyGammaQuickMultiRewardChef is StratFeeManagerInitializable {
    using SafeERC20 for IERC20;

    // Tokens used
    address public native; // NOTE: WMATIC
    address public output; // NOTE: dQuick
    address public want; // NOTE: WMATIC/LCD
    address public lpToken0; // NOTE: WMATIC
    address public lpToken1; // NOTE: LCD

    // Third party contracts
    address public hypervisorProxy; // NOTE: 0xe0a61107e250f8b5b24bf272babfcf638569830c
    address public hypervisor; // NOTE: UniProxy 
    address public chef; // NOTE: Masterchef
    address public algebraV3Router; // NOTE: Quickswap
    uint256 public poolId;

    bool public harvestOnDeposit;
    uint256 public lastHarvest;
    bool public shouldSweep;
    
    ISolidlyRouter.Routes[] public outputToNativeRoute;
    ISolidlyRouter.Routes[] public nativeToLp0Route;
    ISolidlyRouter.Routes[] public nativeToLp1Route;
    address[] public rewards; // NOTE: [dQuick, LCD]
    mapping(address => ISolidlyRouter.Routes[]) public extraRewards;

    event StratHarvest(address indexed harvester, uint256 wantHarvested, uint256 tvl);
    event Deposit(uint256 tvl);
    event Withdraw(uint256 tvl);
    event ChargedFees(uint256 callFees, uint256 beefyFees, uint256 strategistFees);

    function initialize(
        address _want,
        address _hypervisor,
        address _hypervisorProxy,
        address _chef,
        uint256 _poolId,
        CommonAddresses calldata _commonAddresses,
        ISolidlyRouter.Routes[] calldata _outputToNativeRoute,
        ISolidlyRouter.Routes[] calldata _nativeToLp0Route,
        ISolidlyRouter.Routes[] calldata _nativeToLp1Route,
        bool _stable
    )  public initializer  {
         __StratFeeManager_init(_commonAddresses);
        want = _want;
        hypervisor = _hypervisor;
        hypervisorProxy = _hypervisorProxy;
        chef = _chef;
        poolId = _poolId;
        algebraV3Router = address(0xf5b509bB0909a69B1c207E495f687a596C168E12);

        for (uint i; i < _outputToNativeRoute.length; ++i) {
            outputToNativeRoute.push(_outputToNativeRoute[i]);
        }

        for (uint i; i < _nativeToLp0Route.length; ++i) {
            nativeToLp0Route.push(_nativeToLp0Route[i]);
        }

        for (uint i; i < _nativeToLp1Route.length; ++i) {
            nativeToLp1Route.push(_nativeToLp1Route[i]);
        }

        output = outputToNativeRoute[0].from;
        native = outputToNativeRoute[outputToNativeRoute.length -1].to;
        lpToken0 = nativeToLp0Route[nativeToLp0Route.length - 1].to;
        lpToken1 = nativeToLp1Route[nativeToLp1Route.length - 1].to;

        shouldSweep = true;

        rewards.push(output);
        _giveAllowances();
    }

    function _rewardExists(address _reward) private view returns (bool exists) {
        for (uint i; i < rewards.length;) {
            if (rewards[i] == _reward) {
                exists = true;
            }
            unchecked { ++i; }
        }
    }

    function deposit() public whenNotPaused  {
        if (shouldSweep) {
            _deposit();
        }
    }

    // puts the funds to work
    function _deposit() internal whenNotPaused {
        uint256 wantBal = IERC20(want).balanceOf(address(this));

        if (wantBal > 0) {
            IGammaMasterChef(chef).deposit(poolId, wantBal, address(this));
            emit Deposit(balanceOf());
        }
    }

    function withdraw(uint256 _amount) external {
        require(msg.sender == vault, "!vault");

        uint256 wantBal = IERC20(want).balanceOf(address(this));

        if (wantBal < _amount) {
            ISolidlychef(chef).withdraw(poolId, _amount - wantBal, address(this));
            wantBal = IERC20(want).balanceOf(address(this));
        }

        if (wantBal > _amount) {
            wantBal = _amount;
        }

        if (tx.origin != owner() && !paused()) {
            uint256 withdrawalFeeAmount = wantBal * withdrawalFee / WITHDRAWAL_MAX;
            wantBal = wantBal - withdrawalFeeAmount;
        }

        IERC20(want).safeTransfer(vault, wantBal);

        emit Withdraw(balanceOf());
    }

    function beforeDeposit() external virtual override {
        if (harvestOnDeposit) {
            require(msg.sender == vault, "!vault");
            _harvest(tx.origin);
        }
    }

    function harvest() external virtual {
        _harvest(tx.origin);
    }

    function harvest(address callFeeRecipient) external virtual {
        _harvest(callFeeRecipient);
    }

    // compounds earnings and charges performance fee
    function _harvest(address callFeeRecipient) internal whenNotPaused {
        ISolidlychef(chef).harvest(poolId, address(this));
        uint256 outputBal = IERC20(output).balanceOf(address(this));
        if (outputBal > 0) {
            chargeFees(callFeeRecipient);
            addLiquidity();
            uint256 wantHarvested = balanceOfWant();
            _deposit();

            lastHarvest = block.timestamp;
            emit StratHarvest(msg.sender, wantHarvested, balanceOf());
        }
    }

    // performance fees
    function chargeFees(address callFeeRecipient) internal {
        IFeeConfig.FeeCategory memory fees = getFees();
        uint256 toNative = IERC20(output).balanceOf(address(this));
        UniV3Actions.swapV3WithDeadline(algebraV3Router, outputToNativeRoute, toNative);

        if (rewards.length > 1) {
            swapRewards();
        }

        uint256 nativeBal = IERC20(native).balanceOf(address(this)) * fees.total / DIVISOR;

        uint256 callFeeAmount = nativeBal * fees.call / DIVISOR;
        IERC20(native).safeTransfer(callFeeRecipient, callFeeAmount);

        uint256 beefyFeeAmount = nativeBal * fees.beefy / DIVISOR;
        IERC20(native).safeTransfer(beefyFeeRecipient, beefyFeeAmount);

        uint256 strategistFeeAmount = nativeBal * fees.strategist / DIVISOR;
        IERC20(native).safeTransfer(strategist, strategistFeeAmount);

        emit ChargedFees(callFeeAmount, beefyFeeAmount, strategistFeeAmount);
    }
    
    function swapRewards() internal {
        for (uint i; i < rewards.length; ++i) {
            if (rewards[i] != output) {
                uint256 bal = IERC20(rewards[i]).balanceOf(address(this));
                if (bal > 0) {
                    UniV3Actions.swapV3WithDeadline(algebraV3Router, extraRewards[rewards[i]].routeToNative, bal);
                }
            }
        }
    }

    // Adds liquidity to AMM and gets more LP tokens.
    function addLiquidity() internal {
        uint256 nativeBal = IERC20(native).balanceOf(address(this));

        (uint256 total0, uint256 total1) = IHypervisor(hypervisor).getTotalAmounts();
        uint256 ratio = total0 * 1e18 / total1;
        uint256 lp0Amt = nativeBal * ratio / (ratio + 1e18);
        uint256 lp1Amt = nativeBal - lp0Amt;

        if (lpToken0 != native) {
            UniV3Actions.swapV3WithDeadline(algebraV3Router, nativeToLp0Route, lp0Amt);
        }

        if (lpToken1 != native) {
            UniV3Actions.swapV3WithDeadline(algebraV3Router, nativeToLp1Route, lp1Amt);
        }

        uint256 lp0Bal = IERC20(lpToken0).balanceOf(address(this));
        uint256 lp1Bal = IERC20(lpToken1).balanceOf(address(this));
        
        IHypervisorProxy(hypervisorProxy).deposit(lp0Bal, lp1Bal, address(this), address(hypervisor), [0,0,0,0]);
    }

    // calculate the total underlaying 'want' held by the strat.
    function balanceOf() public view returns (uint256) {
        return balanceOfWant() + balanceOfPool();
    }

    // it calculates how much 'want' this contract holds.
    function balanceOfWant() public view returns (uint256) {
        return IERC20(want).balanceOf(address(this));
    }

    // it calculates how much 'want' the strategy has working in the farm.
    function balanceOfPool() public view returns (uint256) {
        return IGammaMasterchef(chef).userInfo(poolId, address(this)).amount;
    }

    // returns rewards unharvested
    function rewardsAvailable() public view returns (uint256) {
        uint256 nativeBal = 0;
        for( uint256 i = 0; i < IGammaMasterchef(chef).poolInfo[pid].rewarders.length; i++) {
            IRewarder _rewarder = IGammaMasterchef(chef).poolInfo[pid].rewarders[i];
            if (address(_rewarder) != address(0)) {
                uint256 pending = _rewarder.pendingToken(pid, to);
                IUniswapRouterV3(algebraV3Router).
            }
        }

        return ISolidlychef(chef).earned(output, address(this));
    }

    // native reward amount for calling harvest
    function callReward() public view returns (uint256) {
        IFeeConfig.FeeCategory memory fees = getFees();
        uint256 outputBal = rewardsAvailable();
        uint256 nativeOut;
        if (outputBal > 0) {
            (nativeOut,) = ISolidlyRouter(unirouter).getAmountOut(outputBal, output, native);
            }

        return nativeOut * fees.total / DIVISOR * fees.call / DIVISOR;
    }


     function setShouldSweep(bool _shouldSweep) external onlyManager {
        shouldSweep = _shouldSweep;
    }

    function sweep() external {
        _deposit();
    }

    function deleteRewards() external onlyManager {
        for (uint i; i < rewards.length; ++i) {
            if (rewards[i] != output) {
                delete extraRewards[rewards[i]];
            }
        }
        delete rewards;
        rewards.push(output);
    }

    function addRewardToken(address _token, ISolidlyRouter.Routes[] calldata _route,  bytes calldata _routeToNative) external onlyOwner {
        require (!_rewardExists(_token), "Reward Exists");
        require (_token != address(want), "Reward Token");
        require (_token != address(output), "Output");

        bool optedIn = ISolidlychef(chef).isOptIn(address(this), _token);
        if (!optedIn) {
            address[] memory tokens = new address[](1);
            tokens[0] = _token;
            ISolidlychef(chef).optIn(tokens);
        }

        if (_route[0].from != address(0)) {
            IERC20(_token).safeApprove(unirouter, 0);
            IERC20(_token).safeApprove(unirouter, type(uint).max);
        } else {
            IERC20(_token).safeApprove(algebraV3Router, 0);
            IERC20(_token).safeApprove(algebraV3Router, type(uint).max);
        }

        rewards.push(_token);
            

        for (uint i; i < _route.length; ++i) {
            extraRewards[_token].rewardToNativeRoute.push(_route[i]);
        }

        extraRewards[_token].routeToNative = _routeToNative;
        extraRewards[_token].useUniV3 = _route[0].from == address(0) ? true : false;
    }

    function emergencyOptOut(address[] memory _tokens) external onlyManager {
        ISolidlychef(chef).emergencyOptOut(_tokens);
    }

    function setHarvestOnDeposit(bool _harvestOnDeposit) external onlyManager {
        harvestOnDeposit = _harvestOnDeposit;

        if (harvestOnDeposit) {
            setWithdrawalFee(0);
        } else {
            setWithdrawalFee(10);
        }
    }

    // called as part of strat migration. Sends all the available funds back to the vault.
    function retireStrat() external {
        require(msg.sender == vault, "!vault");

        ISolidlychef(chef).withdraw(balanceOfPool());

        uint256 wantBal = IERC20(want).balanceOf(address(this));
        IERC20(want).transfer(vault, wantBal);
    }

    // pauses deposits and withdraws all funds from third party systems.
    function panic() public onlyManager {
        pause();
        ISolidlychef(chef).withdraw(balanceOfPool());
    }

    function pause() public onlyManager {
        _pause();

        _removeAllowances();
    }

    function unpause() external onlyManager {
        _unpause();

        _giveAllowances();

        _deposit();
    }

    function _giveAllowances() internal {
        IERC20(want).safeApprove(chef, type(uint).max);
        for (uint i; i < rewards.length; ++i) {
            extraRewards[rewards[i]].useUniV3 
                ? IERC20(rewards[i]).safeApprove(algebraV3Router, type(uint).max)
                : IERC20(rewards[i]).safeApprove(unirouter, type(uint).max);
        }

        IERC20(native).safeApprove(unirouter, 0);
        IERC20(native).safeApprove(unirouter, type(uint).max);

        IERC20(lpToken0).safeApprove(unirouter, 0);
        IERC20(lpToken0).safeApprove(unirouter, type(uint).max);

        IERC20(lpToken1).safeApprove(unirouter, 0);
        IERC20(lpToken1).safeApprove(unirouter, type(uint).max);
    }

    function _removeAllowances() internal {
        IERC20(want).safeApprove(chef, 0);
         for (uint i; i < rewards.length; ++i) {
            extraRewards[rewards[i]].useUniV3 
                ? IERC20(rewards[i]).safeApprove(algebraV3Router, 0)
                : IERC20(rewards[i]).safeApprove(unirouter, 0);
        }

        IERC20(native).safeApprove(unirouter, 0);
        IERC20(lpToken0).safeApprove(unirouter, 0);
        IERC20(lpToken1).safeApprove(unirouter, 0);
    }

    function _solidlyToRoute(ISolidlyRouter.Routes[] memory _route) internal pure returns (address[] memory) {
        address[] memory route = new address[](_route.length + 1);
        route[0] = _route[0].from;
        for (uint i; i < _route.length; ++i) {
            route[i + 1] = _route[i].to;
        }
        return route;
    }

    function outputToNative() external view returns (address[] memory) {
        ISolidlyRouter.Routes[] memory _route = outputToNativeRoute;
        return _solidlyToRoute(_route);
    }

    function nativeToLp0() external view returns (address[] memory) {
        ISolidlyRouter.Routes[] memory _route = nativeToLp0Route;
        return _solidlyToRoute(_route);
    }

    function nativeToLp1() external view returns (address[] memory) {
        ISolidlyRouter.Routes[] memory _route = nativeToLp1Route;
        return _solidlyToRoute(_route);
    }

    function rewardRoute(address _token) external view returns (address[] memory) {
        ISolidlyRouter.Routes[] memory _route = extraRewards[_token].rewardToNativeRoute;
        return _solidlyToRoute(_route);
    }
}