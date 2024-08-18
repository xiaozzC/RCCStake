# RCCStake 合约

`RCCStake` 是一个基于 Solidity 的智能合约，允许用户将代币质押到不同的池子中，并根据预定的奖励规则获得 RCC 代币奖励。合约的主要功能包括池子管理、用户操作、管理员操作和事件通知。

## 合约功能

### 角色定义
- **ADMIN_ROLE**: 管理员角色，拥有设置和管理功能的权限。
- **UPGRADE_ROLE**: 升级角色，负责合约的升级操作。

### 数据结构
- **Pool**: 描述一个质押池，包括质押代币地址、池权重、奖励计算区块、每个代币的累计奖励、质押代币总量、最小质押量和解质押锁定区块数。
- **UnstakeRequest**: 描述用户的提取请求，包括请求金额和解锁区块号。
- **User**: 描述用户在特定池中的信息，包括质押代币数量、已领取的 RCC、待领取的 RCC 和提取请求列表。

### 主要功能

#### 管理池子
- **addPool**: 添加新池子，并可选择是否更新所有池的状态。
- **updatePool**: 更新池的最小存款金额和解质押锁定区块数。
- **setPoolWeight**: 更新池的权重。

#### 用户操作
- **deposit**: 存入质押代币以获取 RCC 奖励。
- **requestUnstake**: 请求提取质押代币。
- **withdraw**: 提取质押代币。
- **claim**: 领取 RCC 奖励。

#### 管理员操作
- **setRCC**: 设置 RCC 代币地址。
- **pauseWithdraw** / **unpauseWithdraw**: 暂停/恢复提取操作。
- **pauseClaim** / **unpauseClaim**: 暂停/恢复领取操作。
- **setStartBlock**: 更新质押的起始区块号。
- **setEndBlock**: 更新质押的结束区块号。
- **setRCCPerBlock**: 更新每个区块奖励的 RCC 数量。

### 事件
- **SetRCC**: 设置 RCC 代币地址事件。
- **PauseWithdraw** / **UnpauseWithdraw**: 暂停/恢复提取事件。
- **PauseClaim** / **UnpauseClaim**: 暂停/恢复领取事件。
- **AddPool**: 添加新池子事件。
- **UpdatePoolInfo**: 更新池子信息事件。
- **SetPoolWeight**: 更新池子权重事件。
- **UpdatePool**: 更新池子奖励事件。
- **Deposit**: 存入代币事件。
- **RequestUnstake**: 请求提取代币事件。
- **Withdraw**: 提取代币事件。
- **Claim**: 领取 RCC 奖励事件。

## 使用说明

1. **初始化合约**
   调用 `initialize` 函数来初始化合约，传入 RCC 代币地址、起始区块号、结束区块号和每个区块奖励的 RCC 数量。

   function initialize(
       IERC20 _RCC,
       uint256 _startBlock,
       uint256 _endBlock,
       uint256 _RCCPerBlock
   ) public initializer;

2. **存入代币**
    使用 deposit 函数将代币存入合约。此操作将更新用户在指定池中的质押量，并根据权重计算 RCC 奖励。

    function deposit(uint256 _pid, uint256 _amount) public;   

3. **存入代币**
    使用 deposit 函数将代币存入合约以获取 RCC 奖励。

    function deposit(uint256 _pid, uint256 _amount) public;

4. **请求提取**
    使用 requestUnstake 函数请求提取质押代币。

    function requestUnstake(uint256 _pid, uint256 _amount) public;

5. **领取奖励**
    使用 claim 函数领取 RCC 奖励。

    function claim(uint256 _pid) public;


安全注意事项
请确保合约部署在安全的环境中，并且所有管理员操作都需要通过合适的权限进行控制。
在使用合约之前，请务必对其进行充分的测试以确保合约的功能和安全性。

许可证
本合约使用 MIT 许可证。