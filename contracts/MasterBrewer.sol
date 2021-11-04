// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "./BrewToken.sol";

// The Potion Brew is a re-imagining of MasterChef by SushiSwap
// Have fun reading it. Hopefully it's bug-free.
contract MasterBrewer is Ownable {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    function blockTime() external view returns (uint256) {
        return block.timestamp;
    }

    // Info of each user.
    struct UserInfo {
        uint256 amount; // How many LP tokens the user has provided.
        uint256 depositTime; // When did the user deposit.
        uint256 rewardDebt; // Reward debt. See explanation below.
        //
        // We do some fancy math here. Basically, any point in time, the amount of BREWs
        // entitled to a user but is pending to be distributed is:
        //
        //   pending reward = (user.amount * pool.accBREWPerShare) - user.rewardDebt
        //
        // Whenever a user deposits or withdraws LP tokens to a pool. Here's what happens:
        //   1. The pool's `accBREWPerShare` (and `lastRewardBlock`) gets updated.
        //   2. Pending is scaled based on depositTime and pool.brewTime
        //   3. Forfeited rewards are re-added to the pool's accBREWPerShare
        //   4. User receives the pending reward sent to his/her address.
        //   5. User's `amount` gets updated.
        //   6. User's `rewardDebt` gets updated.
    }

    // Info of each pool.
    struct PoolInfo {
        IERC20 lpToken; // Address of LP token contract.
        uint256 allocPoint; // How many allocation points assigned to this pool. BREWs to distribute per block.
        uint256 lastRewardTime; // Last block time that BREWs distribution occurs.
        uint256 accBREWPerShare; // Accumulated BREWs per share, times 1e12. See below.
        uint16 depositFeeBP; // Deposit fee in basis points
        uint256 brewTime; // How long does this pool brew
        uint256 lpSupply; // How much is deposited in the pool
    }

    // Brewing up something good!
    BrewToken public brew;

    // Dev address.
    address public devaddr;
    // Fee address.
    address public feeaddr;
    // brew tokens created per block.
    uint256 public brewPerSecond;
    // how much forfeited rewards are distributed in BP
    uint256 public forfeitedDistributionBP = 9500;

    // Info of each pool.
    PoolInfo[] public poolInfo;
    // Info of each user that stakes LP tokens.
    mapping(uint256 => mapping(address => UserInfo)) public userInfo;
    // Total allocation points. Must be the sum of all allocation points in all pools.
    uint256 public totalAllocPoint = 0;
    // The block time when brew mining starts.
    uint256 public immutable startTime;

    event Deposit(address indexed user, uint256 indexed pid, uint256 amount);
    event Withdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event EmergencyWithdraw(
        address indexed user,
        uint256 indexed pid,
        uint256 amount
    );

    constructor(
        BrewToken _brew,
        address _devaddr,
        address _feeaddr,
        uint256 _brewPerSecond,
        uint256 _startTime
    ) {
        brew = _brew;
        devaddr = _devaddr;
        feeaddr = _feeaddr;
        brewPerSecond = _brewPerSecond;
        startTime = _startTime;
    }

    function poolLength() external view returns (uint256) {
        return poolInfo.length;
    }

    // Changes brew token reward per second
    // Good practice to update pools without messing up the contract
    function setBrewPerSecond(uint256 _brewPerSecond) external onlyOwner {
        // This MUST be done or pool rewards will be calculated with new brew per second
        // This could unfairly punish small pools that dont have frequent deposits/withdraws/harvests
        massUpdatePools();

        brewPerSecond = _brewPerSecond;
    }

    function setForfeitedDistribution(uint256 _forfeitedDistributionBP)
        external
        onlyOwner
    {
        massUpdatePools();
        require(forfeitedDistributionBP < 10000, "basis points");

        forfeitedDistributionBP = _forfeitedDistributionBP;
    }

    function checkForDuplicate(IERC20 _lpToken) internal view {
        uint256 length = poolInfo.length;
        for (uint256 _pid = 0; _pid < length; _pid++) {
            require(
                poolInfo[_pid].lpToken != _lpToken,
                "add: pool already exists!!!!"
            );
        }
        // valid ERC20
        _lpToken.balanceOf(address(this));
    }

    // Add a new lp to the pool. Can only be called by the owner.
    function add(
        uint256 _allocPoint,
        IERC20 _lpToken,
        uint16 _depositFeeBP,
        uint256 _brewTime
    ) external onlyOwner {
        checkForDuplicate(_lpToken); // ensure you cant add duplicate pools

        require(_depositFeeBP <= 500, "fee too greedy");

        massUpdatePools();

        uint256 lastRewardTime = block.timestamp > startTime
            ? block.timestamp
            : startTime;
        totalAllocPoint = totalAllocPoint.add(_allocPoint);
        poolInfo.push(
            PoolInfo({
                lpToken: _lpToken,
                allocPoint: _allocPoint,
                lastRewardTime: lastRewardTime,
                accBREWPerShare: 0,
                depositFeeBP: _depositFeeBP,
                brewTime: _brewTime,
                lpSupply: 0
            })
        );
    }

    // Update the given pool's BREW allocation point. Can only be called by the owner.
    function set(
        uint256 _pid,
        uint256 _allocPoint,
        uint16 _depositFeeBP,
        uint256 _brewTime
    ) external onlyOwner {
        massUpdatePools();

        totalAllocPoint =
            totalAllocPoint -
            poolInfo[_pid].allocPoint +
            _allocPoint;
        poolInfo[_pid].allocPoint = _allocPoint;
        poolInfo[_pid].depositFeeBP = _depositFeeBP;
        poolInfo[_pid].brewTime = _brewTime;
    }

    // Return reward multiplier over the given _from to _to block.
    function getMultiplier(uint256 _from, uint256 _to)
        public
        view
        returns (uint256)
    {
        _from = _from > startTime ? _from : startTime;
        if (_to < startTime) {
            return 0;
        }
        return _to - _from;
    }

    // View function to see pending BREWs on frontend.
    function pendingBREW(uint256 _pid, address _user)
        external
        view
        returns (uint256)
    {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_user];
        uint256 accBREWPerShare = pool.accBREWPerShare;
        if (block.timestamp > pool.lastRewardTime && pool.lpSupply != 0) {
            uint256 multiplier = getMultiplier(
                pool.lastRewardTime,
                block.timestamp
            );
            uint256 brewReward = multiplier
                .mul(brewPerSecond)
                .mul(pool.allocPoint)
                .div(totalAllocPoint);
            accBREWPerShare = accBREWPerShare.add(
                brewReward.mul(1e12).div(pool.lpSupply)
            );
        }

        uint256 fullPending = user.amount.mul(accBREWPerShare).div(1e12).sub(
            user.rewardDebt
        );

        uint256 timeBrewing = block.timestamp.sub(user.depositTime);

        return
            timeBrewing < pool.brewTime
                ? fullPending.mul(timeBrewing).div(pool.brewTime)
                : fullPending;
    }

    // Update reward variables for all pools. Be careful of gas spending!
    function massUpdatePools() public {
        uint256 length = poolInfo.length;
        for (uint256 pid = 0; pid < length; ++pid) {
            updatePool(pid);
        }
    }

    // Update reward variables of the given pool to be up-to-date.
    function updatePool(uint256 _pid) public {
        PoolInfo storage pool = poolInfo[_pid];
        if (block.timestamp <= pool.lastRewardTime) {
            return;
        }
        if (pool.lpSupply == 0) {
            pool.lastRewardTime = block.timestamp;
            return;
        }
        uint256 multiplier = getMultiplier(
            pool.lastRewardTime,
            block.timestamp
        );
        uint256 brewReward = multiplier
            .mul(brewPerSecond)
            .mul(pool.allocPoint)
            .div(totalAllocPoint);

        brew.mint(devaddr, brewReward.div(10));
        brew.mint(address(this), brewReward);

        pool.accBREWPerShare = pool.accBREWPerShare.add(
            brewReward.mul(1e12).div(pool.lpSupply)
        );
        pool.lastRewardTime = block.timestamp;
    }

    // Deposit LP tokens to MasterChef for BREW allocation.
    function deposit(uint256 _pid, uint256 _amount) public {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];

        updatePool(_pid);

        uint256 fullPending = user
            .amount
            .mul(pool.accBREWPerShare)
            .div(1e12)
            .sub(user.rewardDebt);

        uint256 pending = 0;
        uint256 timeBrewing = block.timestamp.sub(user.depositTime);

        if (user.amount > 0) {
            if (timeBrewing < pool.brewTime) {
                pending = fullPending.mul(timeBrewing).div(pool.brewTime);
                // distribute forfeited awards back to farmers
                uint256 forfeited = fullPending.sub(pending);
                uint256 distributed = forfeited
                    .mul(forfeitedDistributionBP)
                    .div(10000);
                safeBREWTransfer(feeaddr, forfeited.sub(distributed));
                pool.accBREWPerShare = pool.accBREWPerShare.add(
                    (distributed).mul(1e12).div(pool.lpSupply)
                );
            } else {
                pending = fullPending;
            }
        }

        if (pending > 0) {
            safeBREWTransfer(msg.sender, pending);
        }

        if (_amount > 0) {
            if (user.amount > 0) {
                if (_amount >= user.amount.mul(2)) {
                    user.depositTime = block.timestamp;
                } else {
                    if (timeBrewing >= pool.brewTime) {
                        uint256 adjLastDepositTime = block.timestamp.sub(
                            pool.brewTime
                        );
                        user.depositTime = adjLastDepositTime.add(
                            _amount.mul(pool.brewTime).div(user.amount).div(2)
                        );
                    } else {
                        uint256 newDepositTime = user.depositTime.add(
                            _amount.mul(pool.brewTime).div(user.amount).div(2)
                        );
                        user.depositTime = newDepositTime > block.timestamp
                            ? block.timestamp
                            : newDepositTime;
                    }
                }
            } else {
                user.depositTime = block.timestamp;
            }
            uint256 balanceBefore = pool.lpToken.balanceOf(address(this));
            pool.lpToken.safeTransferFrom(
                address(msg.sender),
                address(this),
                _amount
            );
            _amount = pool.lpToken.balanceOf(address(this)) - balanceBefore;
            if (pool.depositFeeBP > 0) {
                uint256 depositFee = _amount.mul(pool.depositFeeBP).div(10000);
                pool.lpToken.safeTransfer(feeaddr, depositFee);
                user.amount = user.amount.add(_amount).sub(depositFee);
                pool.lpSupply = pool.lpSupply.add(_amount).sub(depositFee);
            } else {
                user.amount = user.amount.add(_amount);
                pool.lpSupply = pool.lpSupply.add(_amount);
            }
        }
        user.rewardDebt = user.amount.mul(pool.accBREWPerShare).div(1e12);
        emit Deposit(msg.sender, _pid, _amount);
    }

    // Withdraw LP tokens from MasterChef.
    function withdraw(uint256 _pid, uint256 _amount) public {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];

        require(user.amount >= _amount, "withdraw: not good");

        updatePool(_pid);

        uint256 fullPending = user
            .amount
            .mul(pool.accBREWPerShare)
            .div(1e12)
            .sub(user.rewardDebt);

        uint256 pending = 0;

        uint256 timeBrewing = block.timestamp.sub(user.depositTime);

        if (timeBrewing < pool.brewTime) {
            pending = fullPending.mul(timeBrewing).div(pool.brewTime);
            // distribute forfeited awards back to farmers
            uint256 forfeited = fullPending.sub(pending);
            uint256 distributed = forfeited.mul(forfeitedDistributionBP).div(
                10000
            );
            safeBREWTransfer(feeaddr, forfeited.sub(distributed));
            if (pool.lpSupply.sub(_amount) > 0) {
                pool.accBREWPerShare = pool.accBREWPerShare.add(
                    (distributed).mul(1e12).div(pool.lpSupply.sub(_amount))
                );
            }
        } else {
            pending = fullPending;
        }

        user.depositTime = block.timestamp;
        user.amount = user.amount.sub(_amount);
        pool.lpSupply = pool.lpSupply.sub(_amount);
        user.rewardDebt = user.amount.mul(pool.accBREWPerShare).div(1e12);

        if (pending > 0) {
            safeBREWTransfer(msg.sender, pending);
        }
        pool.lpToken.safeTransfer(address(msg.sender), _amount);

        emit Withdraw(msg.sender, _pid, _amount);
    }

    // Withdraw without caring about rewards. EMERGENCY ONLY.
    function emergencyWithdraw(uint256 _pid) public {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];

        uint256 oldUserAmount = user.amount;
        user.amount = 0;
        user.rewardDebt = 0;
        user.depositTime = 0;

        if (pool.lpSupply >= oldUserAmount) {
            pool.lpSupply = pool.lpSupply.sub(oldUserAmount);
        } else {
            pool.lpSupply = 0;
        }

        pool.lpToken.safeTransfer(address(msg.sender), oldUserAmount);
        emit EmergencyWithdraw(msg.sender, _pid, oldUserAmount);
    }

    // Safe brew transfer function, just in case if rounding error causes pool to not have enough BREWs.
    function safeBREWTransfer(address _to, uint256 _amount) internal {
        uint256 brewBal = brew.balanceOf(address(this));
        if (_amount > brewBal) {
            brew.transfer(_to, brewBal);
        } else {
            brew.transfer(_to, _amount);
        }
    }

    // Update dev address by the previous dev.
    function dev(address _devaddr) public {
        require(msg.sender == devaddr, "dev: wut?");
        devaddr = _devaddr;
    }

    function fee(address _feeaddr) public {
        require(msg.sender == feeaddr, "FORBIDDEN");
        feeaddr = _feeaddr;
    }
}
