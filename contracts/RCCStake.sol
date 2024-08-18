// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";


/**
 * RCCStake合约它允许用户将代币质押到不同的池子中，并在每个区块中根据预定的奖励规则获得 RCC 代币奖励。
 *  主要功能包括：
 *  管理池子：添加、更新池子，以及调整池子的权重和参数。
 *  用户操作：质押 (deposit)、请求解押 (unstake)、提款 (withdraw) 和领取奖励 (claim)。
 *  管理员操作：包括暂停/取消暂停提款和领取奖励、设置 RCC 代币地址、更新奖励参数等。
 *  事件通知：用于跟踪用户和管理员操作的事件。
 */

contract RCCStake is
    Initializable,
    UUPSUpgradeable,
    PausableUpgradeable,
    AccessControlUpgradeable
{
    using SafeERC20 for IERC20;
    using Address for address;
    using Math for uint256;

    // ************************************** 角色定义 **************************************
    bytes32 public constant ADMIN_ROLE = keccak256("admin_role");
    bytes32 public constant UPGRADE_ROLE = keccak256("upgrade_role");

    uint256 public constant nativeCurrency_PID = 0;

    /**
     *  基本上，任何时候，用户待分配的 RCC 数量为：
        待分配 RCC = (用户的 stAmount * 池的 accRCCPerST) - 用户的 finishedRCC
        每当用户存入或取出池中的质押代币时，发生以下情况：
        1. 池的 `accRCCPerST`（和 `lastRewardBlock`）会被更新。
        2. 用户接收待分配的 RCC 发送到他的地址。
        3. 用户的 `stAmount` 会被更新。
        4. 用户的 `finishedRCC` 会被更新。
     */

    // ************************************** 数据结构 **************************************
    struct Pool {
        // 质押代币地址
        address stTokenAddress;
        // 池的权重
        uint256 poolWeight;
        // 上次分发 RCC 的区块号
        uint256 lastRewardBlock;
        // 每个质押代币的累计 RCC
        uint256 accRCCPerST;
        // 质押代币总量
        uint256 stTokenAmount;
        // 最小质押量
        uint256 minDepositAmount;
        // 提取锁定区块数
        uint256 unstakeLockedBlocks;
    }

    struct UnstakeRequest {
        // 请求提取的金额
        uint256 amount;
        // 请求提取金额的解锁区块号
        uint256 unlockBlocks;
    }

    struct User {
        // 用户提供的质押代币数量
        uint256 stAmount;
        // 已分配给用户的 RCC
        uint256 finishedRCC;
        // 待领取的 RCC
        uint256 pendingRCC;
        // 提取请求列表
        UnstakeRequest[] requests;
    }

    // ************************************** 状态变量 **************************************
    // RCCStake 合约的开始区块
    uint256 public startBlock;
    // RCCStake 合约的结束区块
    uint256 public endBlock;
    // 每区块的 RCC 奖励
    uint256 public RCCPerBlock;

    // 暂停提取功能
    bool public withdrawPaused;
    // 暂停领取功能
    bool public claimPaused;

    // RCC 代币
    IERC20 public RCC;

    // 总权重 / 所有池权重之和
    uint256 public totalPoolWeight;
    Pool[] public pool;

    // 池id => 用户地址 => 用户信息
    mapping(uint256 => mapping(address => User)) public user;

    // ************************************** 事件 **************************************
    event SetRCC(IERC20 indexed RCC);
    event PauseWithdraw();
    event UnpauseWithdraw();
    event PauseClaim();
    event UnpauseClaim();
    event SetStartBlock(uint256 indexed startBlock);
    event SetEndBlock(uint256 indexed endBlock);
    event SetRCCPerBlock(uint256 indexed RCCPerBlock);
    event AddPool(
        address indexed stTokenAddress,
        uint256 indexed poolWeight,
        uint256 indexed lastRewardBlock,
        uint256 minDepositAmount,
        uint256 unstakeLockedBlocks
    );
    event UpdatePoolInfo(
        uint256 indexed poolId,
        uint256 indexed minDepositAmount,
        uint256 indexed unstakeLockedBlocks
    );
    event SetPoolWeight(
        uint256 indexed poolId,
        uint256 indexed poolWeight,
        uint256 totalPoolWeight
    );
    event UpdatePool(
        uint256 indexed poolId,
        uint256 indexed lastRewardBlock,
        uint256 totalRCC
    );
    event Deposit(address indexed user, uint256 indexed poolId, uint256 amount);
    event RequestUnstake(
        address indexed user,
        uint256 indexed poolId,
        uint256 amount
    );
    event Withdraw(
        address indexed user,
        uint256 indexed poolId,
        uint256 amount,
        uint256 indexed blockNumber
    );
    event Claim(
        address indexed user,
        uint256 indexed poolId,
        uint256 RCCReward
    );

    // ************************************** 修饰符 **************************************
    modifier checkPid(uint256 _pid) {
        require(_pid < pool.length, "Invalid pool id");
        _;
    }

    modifier whenNotClaimPaused {
        require(!claimPaused,"claim is paused");
        _;
    }

    modifier whenNotWithdrawPaused {
        require(!withdrawPaused,"withdraw is paused");
        _;
    }

    /**
     * 初始化函数
     * @param _RCC IERC20 标准的代币合约地址
     * @param _startBlock 奖励或操作开始的区块编号
     * @param _endBlock 奖励或操作结束的区块编号
     * @param _RCCPerBlock 每个区块要分配的 RCC 代币数量
     */
    function initialize(
        IERC20 _RCC,
        uint256 _startBlock,
        uint256 _endBlock,
        uint256 _RCCPerBlock
    )public initializer{ // 函数是公开的，并且只能调用一次（由 initializer 修饰符保证）

        // 确保开始区块小于或等于结束区块，且每区块分发的 RCC 数量大于 0
        require(_startBlock <= _endBlock && _RCCPerBlock > 0,"invalid parameters");

        // 初始化父合约的功能模块，分别是访问控制和 UUPS 升级模块
        __AccessControl_init();
        __UUPSUpgradeable_init();

        // 授予调用者（通常是合约部署者）默认管理员角色、升级角色和一般管理员角色
        _grantRole(DEFAULT_ADMIN_ROLE,msg.sender);
        _grantRole(UPGRADE_ROLE,msg.sender);
        _grantRole(ADMIN_ROLE,msg.sender);

        // 调用 setRCC 函数，将传入的 RCC 代币合约地址设置到合约中
        setRCC(_RCC);

        // 将传入的参数值赋给合约中的状态变量
        startBlock = _startBlock;
        endBlock = _endBlock;
        RCCPerBlock = _RCCPerBlock;
    }

    function _authorizeUpgrade(address newImplementation)
        internal
        onlyRole(UPGRADE_ROLE)
        override
    {}

    /**
     * @notice Set RCC token address. Can only be called by admin
     * @dev 用来设置 RCC 代币的合约地址，并且只能由拥有管理员角色的账户调用。
     */
    function setRCC(IERC20 _RCC) public onlyRole(ADMIN_ROLE) {
        RCC = _RCC;   // 将传入的 IERC20 代币合约地址赋值给合约中的 RCC 状态变量

        emit SetRCC(RCC); 
    }

    /**
     * @notice Pause withdraw. Can only be called by admin.
     * @dev 用于暂停取款操作，并且只能由拥有管理员角色的账户调用。
     *      如果取款已经被暂停，再次调用该函数将会失败。
     */
    function pauseWithdraw() public onlyRole(ADMIN_ROLE){
        require(!withdrawPaused , "withdraw has been already paused");

        withdrawPaused = true;

        emit PauseWithdraw();
    }

    /**
     * @notice Unpause withdraw. Can only be called by admin.
     * @dev 用于恢复取款操作，并且只能由拥有管理员角色的账户调用。
     *      如果取款已经恢复，再次调用该函数将会失败。
     */
    function unpauseWithdraw() public onlyRole(ADMIN_ROLE){
        require(withdrawPaused , "withdraw has been already unpaused");

        withdrawPaused = true;

        emit UnpauseWithdraw();
    }

    /**
     * @notice Pause claim. Can only be called by admin.
     * @dev 用于暂停领取操作，并且只能由拥有管理员角色的账户调用。
     *      如果领取已经暂停，再次调用该函数将会失败。
     */
    function pauseClaim() public onlyRole(ADMIN_ROLE){
        require(!claimPaused, "claim has been already paused");

        claimPaused = true;

        emit PauseClaim();
    }

    /**
     * @notice Unpause claim. Can only be called by admin.
     * @dev 用于恢复领取操作，并且只能由拥有管理员角色的账户调用。
     *      如果领取已经恢复，再次调用该函数将会失败。
     */
    function unpauseClaim() public onlyRole(ADMIN_ROLE){
        require(claimPaused, "claim has been already unpaused");

        claimPaused = false;

        emit UnpauseClaim();
    }

    /**
     * @notice Update staking start block. Can only be called by admin.
     * @dev 用于更新质押的起始区块号，并且只能由管理员调用。
     *      函数确保新的起始区块号不能大于结束区块号。
     */
    function setStartBlock(uint256 _startBlock) public onlyRole(ADMIN_ROLE){
        require(_startBlock <= endBlock ,"start block must be smaller than end block");
        startBlock = _startBlock;
        emit SetStartBlock(_startBlock);
    }

    /**
     * @notice Update staking end block. Can only be called by admin.
     * @dev 用于更新质押的结束区块号，并且只能由管理员调用。
     *      函数确保新的结束区块号不能小于起始区块号。
     */
    function setEndBlock(uint256 _endBlock) public onlyRole(ADMIN_ROLE){
        require(startBlock <= _endBlock , "start block must be smaller than end block");
        endBlock = _endBlock;
        emit SetEndBlock(_endBlock);
    }

    /**
     * @notice Update the RCC reward amount per block. Can only be called by admin.
     * @dev 该函数用于更新每个区块奖励的 RCC 数量，并且只能由管理员调用。
     *      函数确保新的奖励数量大于 0。
     */
    function setRCCPerBlock(uint256 _RCCPerBlock) public onlyRole(ADMIN_ROLE) {
        require(_RCCPerBlock > 0,"invalid parameter");
        RCCPerBlock = _RCCPerBlock;
        emit SetRCCPerBlock(_RCCPerBlock);
    }

    /**
     * @notice 向合约中添加一个新的质押池。只有管理员可以调用。
     * @dev 确保每个质押代币只能添加一次，以避免 RCC 奖励出现问题。
     * @param _stTokenAddress 质押代币合约的地址（对于原生货币池，地址应为 0x0）。
     * @param _poolWeight 池的权重，决定了 RCC 奖励的分配比例。
     * @param _minDepositAmount 该池的最小存款金额（允许为 0）。
     * @param _unstakeLockedBlocks 取消质押后提款的锁定区块数。
     * @param _withUpdate 是否在添加新池之前更新所有池的状态。
     */
    function addPool(address _stTokenAddress,uint256 _poolWeight,uint256 _minDepositAmount,uint256 _unstakeLockedBlocks,bool _withUpdate) 
        public onlyRole(ADMIN_ROLE)
    {
        // 确保质押代币地址有效，根据是否是第一个池进行检查
        if(pool.length > 0){
            // 如果不是第一个池，则质押代币地址不能为 0x0
            require(_stTokenAddress != address(0x0) , "invalid staking token address");
        }else{
            // 如果是第一个池，则质押代币地址必须为 0x0
            require(_stTokenAddress == address(0x0), "invalid staking token address");
        }

        // 检查取消质押锁定区块数是否有效
        require(_unstakeLockedBlocks > 0,"invalid withdraw locked blocks");

        // 确保在结束区块之前才能添加新的池
        require(block.number < endBlock,"Already ended");

        // 如果请求，更新所有池的状态
        if (_withUpdate) {
            massUpdatePools();
        }

        // 设置最后奖励计算的区块号，取当前区块和开始区块中较大的值
        uint256 lastRewardBlock = block.number > startBlock ? block.number:startBlock;

        // 更新总池权重
        totalPoolWeight = totalPoolWeight + _poolWeight;

        // 将新池的参数初始化并添加到池数组中
        pool.push(Pool({
            stTokenAddress: _stTokenAddress,  // 质押代币地址
            poolWeight: _poolWeight,          // 池的权重
            lastRewardBlock: lastRewardBlock, // 奖励计算的最后区块
            accRCCPerST: 0,                   // 每个质押代币的累计 RCC 奖励，初始为 0
            stTokenAmount: 0,                 // 池中质押代币的总量，初始为 0
            minDepositAmount: _minDepositAmount, // 该池的最小存款金额
            unstakeLockedBlocks: _unstakeLockedBlocks // 取消质押后提款的锁定区块数
        }));
        
        emit AddPool(_stTokenAddress, _poolWeight, lastRewardBlock, _minDepositAmount, _unstakeLockedBlocks);
    }

    /**
     * @notice 更新所有池的奖励变量
     */
    function massUpdatePools() public {
        uint256 length = pool.length;  // 获取池数组的长度
        for (uint256 pid = 0; pid < length; pid++) {  // 遍历所有池
            updatePool(pid);  // 更新每个池的奖励变量
        }
    }

    /**
     * @notice 更新指定池的奖励变量，使其保持最新状态。
     * @param _pid 指定要更新的池的索引。
     */
    function updatePool(uint256 _pid) public checkPid(_pid) {
        Pool storage pool_ = pool[_pid];

        // 如果当前区块号不大于上次奖励计算的区块号，则无需更新，直接返回
        if(block.number <= pool_.lastRewardBlock){
            return;
        }

        // 获取池中的总质押代币数量
        uint256 stSupply = pool_.stTokenAmount;
        if(stSupply == 0){
            // 如果没有代币被质押，更新最后奖励区块为当前区块
            pool_.lastRewardBlock = block.number; 
            return;
        }

        // 计算两个区块之间的乘数
        uint256 multiplier = getMultiplier(pool_.lastRewardBlock, block.number);
        // 根据权重计算这个池的RCC奖励
        uint256 rccReward = multiplier * RCCPerBlock * pool_.poolWeight / totalPoolWeight;
        // 更新每个代币的累计RCC数量
        pool_.accRCCPerST += rccReward * 1e18 / stSupply;
        // 更新池的最后奖励计算区块号为当前区块号
        pool_.lastRewardBlock = block.number;

        emit UpdatePool(_pid,pool_.lastRewardBlock,rccReward);
    }

    /**
     * @notice 返回指定区间 [_from, _to) 的奖励乘数。
     *
     * @param _from    起始区块号（包含）
     * @param _to      结束区块号（不包含）
     * @return multiplier  奖励乘数
     */
    function getMultiplier(uint256 _from, uint256 _to) public view returns(uint256 multiplier){
        // 确保起始区块号不大于结束区块号
        require(_from <= _to,"invalid block range");

        // 如果起始区块号早于开始区块，则将起始区块号设置为开始区块
        if (_from < startBlock) {
            _from = startBlock;
        }

        // 如果结束区块号晚于结束区块，则将结束区块号设置为结束区块
        if (_to > endBlock) {
            _to = endBlock;
        }

        // 确保调整后的区块号范围有效
        require(_from <= _to, "end block must be greater than start block");

        // 计算奖励乘数：区块范围乘以每块奖励
        return (_to - _from) * RCCPerBlock;
    }

    /**
     * @notice 更新指定质押池的信息（最小存款金额和解质押锁定区块数）。仅管理员可以调用。
     */
    function updatePool(uint256 _pid,uint256 _minDepositAmount, uint256 _unstakeLockedBlocks) public onlyRole(ADMIN_ROLE) checkPid(_pid){
        pool[_pid].minDepositAmount = _minDepositAmount;
        pool[_pid].unstakeLockedBlocks = _unstakeLockedBlocks;

        emit UpdatePoolInfo(_pid,_minDepositAmount,_unstakeLockedBlocks);
    }

    /**
     * @notice 更新指定质押池的权重。仅管理员可以调用。
     * @param _pid  质押池的 ID
     * @param _poolWeight  新的池权重，必须大于0
     * @param _withUpdate  是否在更新池权重时进行池的整体更新
     */
    function setPoolWeight(uint256 _pid,uint256 _poolWeight,bool _withUpdate) public onlyRole(ADMIN_ROLE) checkPid(_pid){
        // 确保新的池权重大于0
        require(_poolWeight > 0, "invalid pool weight");

        // 如果指定了进行整体更新，则调用 massUpdatePools 函数
        if(_withUpdate){
            massUpdatePools();
        }

        // 获取当前池的权重
        uint256 currentPoolWeight = pool[_pid].poolWeight;
        
        // 如果权重没有变化，则直接返回，避免不必要的状态写入
        if(currentPoolWeight == _poolWeight){
            return;
        }

        // 更新总池权重：
        // 1. 减去当前池的权重
        // 2. 加上新的权重
        totalPoolWeight = totalPoolWeight - currentPoolWeight + _poolWeight;
        // 更新指定池的权重
        pool[_pid].poolWeight = _poolWeight;

        emit SetPoolWeight(_pid,_poolWeight,totalPoolWeight);
    }

    /**
     * 池子数量
     */
    function poolLength() external view returns(uint256) {
        return pool.length;
    }

    /**
     * @notice 获取用户在指定池子中的待领取RCC数量
     */
    function pendingRCC(uint256 _pid,address _user) external checkPid(_pid) view returns(uint256){
        return pendingRCCByBlockNumber(_pid,_user,block.number);
    }

    /**
     * @notice 根据区块号获取用户在指定池子中的待领取RCC数量
     */
    function pendingRCCByBlockNumber(uint256 _pid,address _user,uint256 _blockNumber)
        public 
        checkPid(_pid)
        view
        returns(uint256)
    {
        Pool storage pool_ = pool[_pid];
        User storage user_ = user[_pid][_user];

        // 获取池子的每单位ST代币的累积RCC奖励数
        uint256 accRCCPerST = pool_.accRCCPerST;
        // 获取池子中的总质押代币数量
        uint256 stSupply = pool_.stTokenAmount;

        // 如果给定的区块号大于上次发放奖励的区块号，且池中有质押代币
        if(_blockNumber > pool_.lastRewardBlock && stSupply != 0){
            // 计算从上次奖励区块到指定区块的区间内生成的块数
             uint256 multiplier = getMultiplier(pool_.lastRewardBlock,_blockNumber);

             // 计算在这段时间内分配给该池子的总RCC奖励
             uint256 RCCForPool = multiplier * pool_.poolWeight / totalPoolWeight;

             // 更新每单位ST代币的累积RCC奖励数
             // `(1 ether)` 用于保证精度，因为 Solidity 不支持小数运算
             accRCCPerST = accRCCPerST + RCCForPool * (1 ether) / stSupply;
        }
        // 计算并返回用户在该区块号的待领取RCC数量
        // `user_.stAmount * accRCCPerST / (1 ether)` 表示用户当前的总RCC奖励
        // 减去用户已经领取的部分，加上还未领取的RCC部分
        return user_.stAmount * accRCCPerST / (1 ether) - user_.finishedRCC + user_.pendingRCC;
    }

    /**
     * @notice 获取用户的质押金额
     */
    function stakingBalance(uint256 _pid,address _user) public checkPid(_pid) view returns(uint256){
        return user[_pid][_user].stAmount;
    }

    /**
     * @notice 获取提现金额信息，包括锁定的和解锁的未质押金额
     */
    function withdrawAmount(uint256 _pid,address _user) public checkPid(_pid) view returns(uint256 requestAmount, uint256 pendingWithdrawAmount){
        User  storage user_ = user[_pid][_user];

        // 遍历用户的所有提现请求
        for(uint256 i = 0; i < user_.requests.length; i++){
            // 检查请求是否解锁
            if(user_.requests[i].unlockBlocks <= block.number){
                // 如果已经解锁，将该请求的金额累加到已解锁的提现金额
                pendingWithdrawAmount = pendingWithdrawAmount + user_.requests[i].amount;
            }
            // 无论解锁与否，将该请求的金额累加到总的申请金额
            requestAmount = requestAmount + user_.requests[i].amount;
        }
    }

    /**
     * @notice 存入原生币（nativeCurrency）以获取RCC奖励
     */
    function depositnativeCurrency() public whenNotPaused() payable{
        // 从存储中获取与原生币相关的质押池（nativeCurrency_PID）信息
        Pool storage pool_ = pool[nativeCurrency_PID];

        // 检查质押池的质押代币地址是否为0x0地址（通常表示支持原生币）
        require(pool_.stTokenAddress == address(0x0), "invalid staking token address");

        // 获取用户在调用函数时发送的原生币数量（msg.value）
        uint256 _amount = msg.value;

        // 检查存款金额是否大于等于质押池要求的最小存款金额
        require(_amount >= pool_.minDepositAmount, "deposit amount is too small");

        // 调用内部函数进行存款处理，传入质押池ID（nativeCurrency_PID）和存款金额（_amount）
        _deposit(nativeCurrency_PID, _amount);
    }

    /**
     * @notice 存入质押代币以获取RCC奖励
     * 在存款之前，用户需要先批准（approve）该合约，以允许合约花费或转移他们的质押代币
     *
     * @param _pid       要存入的池子的ID
     * @param _amount    要存入的质押代币的数量
     */
    function deposit(uint256 _pid,uint256 _amount) public whenNotPaused() checkPid(_pid){
        // 检查是否是有效的池子ID（0表示不支持原生币质押）
        require(_pid != 0, "deposit not support nativeCurrency staking");

        Pool storage pool_ = pool[_pid];

        require(_amount >= pool_.minDepositAmount, "deposit amount is too small");

        // 如果存款金额大于0，则从用户地址将指定数量的质押代币转移到合约地址
        if(_amount > 0){
            IERC20(pool_.stTokenAddress).safeTransferFrom(msg.sender, address(this), _amount);
        }
        // 调用内部函数进行存款处理，传入池子ID（_pid）和存款金额（_amount）
        _deposit(_pid,_amount);
    }

    /**
     * @notice 从池子中解除质押代币
     *
     * @param _pid       要从中解除质押的池子的ID
     * @param _amount    要解除质押的质押代币数量
     */
    function unstake(uint256 _pid, uint256 _amount) public checkPid(_pid) whenNotPaused() whenNotWithdrawPaused(){
        Pool storage pool_ = pool[_pid];
        User storage user_ = user[_pid][msg.sender];
        // 确保用户的质押代币余额足够
        require(user_.stAmount >= _amount,"Not enough staking token balance");

        // 更新池子的状态（如计算新的奖励）
        updatePool(_pid);
        
        // 计算用户当前的待领取RCC奖励
        uint256 pendingRCC_ = (user_.stAmount * pool_.accRCCPerST) / 1 ether - user_.finishedRCC;
        // 如果有待领取的RCC奖励，更新用户的待领取奖励
        if(pendingRCC_ > 0){
            user_.pendingRCC += pendingRCC_;
        }

        // 如果解除质押金额大于0
        if(_amount > 0){
            // 从用户的质押代币余额中扣除解除质押的金额
            user_.stAmount -= _amount;

            // 创建解除质押请求并将其添加到用户的请求列表中
            user_.requests.push(UnstakeRequest({
                amount : _amount,
                unlockBlocks : block.number + pool_.unstakeLockedBlocks
            }));
        }

        // 更新池子的质押代币总量
        pool_.stTokenAmount -= _amount;

        // 计算用户解除质押后的已完成RCC奖励
        user_.finishedRCC = (user_.stAmount * pool_.accRCCPerST) / 1 ether;

        emit RequestUnstake(msg.sender, _pid, _amount);
    }

    /**
     * @notice 提取解锁的解除质押金额
     *
     */
    function withdraw(uint256 _pid) public checkPid(_pid) whenNotWithdrawPaused() whenNotPaused(){
        Pool storage pool_ = pool[_pid];
        User storage user_ = user[_pid][msg.sender];

        uint256 pendingWithdraw_;  // 待提取的金额
        uint256 popNum_;           // 需要从请求列表中移除的请求数量

        uint256 requestsLength = user_.requests.length;
        for(uint256 i; i < requestsLength; i++){
            // 如果请求尚未解锁，则跳过
            if(user_.requests[i].unlockBlocks > block.number){
                break;
            }
             // 累加待提取的金额
            pendingWithdraw_ += user_.requests[i].amount;
            // 计算需要移除的请求数量
            popNum_++;
        }

        
        if(popNum_ > 0){
            // 将未过期的请求移到列表前面
            for (uint256 i = 0; i < requestsLength - popNum_; i++){
                user_.requests[i] = user_.requests[i + popNum_];
            }

            // 移除已完成的解除质押请求
            for (uint256 i = 0; i < popNum_; i++) {
                user_.requests.pop();
            }
        }
        
        // 如果有待提取的金额
        if(pendingWithdraw_ > 0){
            // 根据池子的代币地址决定转账方式
            if(pool_.stTokenAddress == address(0x0)){
                // 如果代币地址是0x0，表示使用原生币进行转账
                _safenativeCurrencyTransfer(msg.sender, pendingWithdraw_);
            }else{
                IERC20(pool_.stTokenAddress).safeTransfer(msg.sender, pendingWithdraw_);
            }
        }

        emit Withdraw(msg.sender, _pid, pendingWithdraw_, block.number);
    }

    /**
     * @notice 领取 RCC 代币奖励
     *
     */
    function claim(uint256 _pid) public checkPid(_pid) whenNotClaimPaused() whenNotPaused(){
        Pool storage pool_ = pool[_pid];
        User storage user_ = user[_pid][msg.sender];

        // 更新池子的奖励信息
        updatePool(_pid);

        // 计算用户的待领取奖励 RCC 代币数量
        uint256 pendingRCC_ = (user_.stAmount * pool_.accRCCPerST / 1 ether) - user_.finishedRCC + user_.pendingRCC;
        // 如果有待领取的 RCC 代币，则进行转账
        if(pendingRCC_ > 0){
             user_.pendingRCC = 0;  // 重置用户的待领取 RCC 数量
            _safeRCCTransfer(msg.sender, pendingRCC_);  // 安全转账 RCC 代币
        }

        // 更新用户已完成的 RCC 代币领取数量
        user_.finishedRCC = user_.stAmount * pool_.accRCCPerST / 1 ether;

        emit Claim(msg.sender, _pid, pendingRCC_);

    }


    // ************************************** 内部函数 **************************************

    /**
     * 存入质押代币以获取RCC奖励
     * @param _pid 要存入的池子的ID
     * @param _amount 要存入的质押代币的数量
     */
    function _deposit(uint256 _pid,uint256 _amount) internal{
        Pool storage pool_ = pool[_pid];
        User storage user_ = user[_pid][msg.sender];

        // 更新池子的状态（如计算新的奖励）
        updatePool(_pid);

        // 如果用户之前有质押代币
        if(user_.stAmount > 0){
            // 计算用户已获得的RCC奖励
            uint256 accST = (user_.stAmount * pool_.accRCCPerST) / 1 ether;
            // 计算待领取的RCC奖励
            uint256 pendingRCC_ = accST - user_.finishedRCC;

            if(pendingRCC_ > 0){
                user_.pendingRCC += pendingRCC_;
            }
        }

        // 更新用户的质押代币数量
        if(_amount > 0){
            user_.stAmount += _amount;
        }

        // 更新池子的质押代币总量
        pool_.stTokenAmount += _amount;

        // 计算用户当前质押代币所能获得的RCC奖励
        uint256 finishedRCC = (user_.stAmount * pool_.accRCCPerST) / 1 ether;
        // 更新用户的已完成RCC奖励
        user_.finishedRCC = finishedRCC;

        emit Deposit(msg.sender, _pid, _amount);
    }

    /**
     * @notice 安全的原生币转账函数
     *
     * @param _to        接收原生币的地址
     * @param _amount    要转账的原生币数量
     */
    function _safenativeCurrencyTransfer(address _to,uint256 _amount) internal{
        (bool success, bytes memory data) =  address(_to).call{
            value : _amount
        }("");

        require(success,"nativeCurrency transfer call failed");

        // 如果返回数据长度大于0，则进一步检查返回的数据
        if(data.length > 0){
            // 解码返回的数据，并确保返回的布尔值为 true
            require(
                abi.decode(data, (bool)),
                "nativeCurrency transfer operation did not succeed"
            );
        }
    }

    /**
     * @notice 安全的 RCC 转账函数，用于防止因舍入误差导致池子中的 RCC 代币不足
     *
     * @param _to        接收 RCC 代币的地址
     * @param _amount    要转账的 RCC 代币数量
     */
    function _safeRCCTransfer(address _to,uint256 _amount) internal{
        // 获取当前合约中 RCC 代币的余额
        uint256 RCCBal = RCC.balanceOf(address(this));

        // 如果要转账的数量大于合约余额，转账全部余额；否则，转账指定数量
        if(_amount > RCCBal){
            // 如果请求的数量超过余额，只转账余额部分
            RCC.transfer(_to, RCCBal);
        }else{
            RCC.transfer(_to, _amount);
        }
    }
    

}