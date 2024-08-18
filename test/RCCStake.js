const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("RCCStake Contract", function () {
    let RCCStake, rccStake, owner, addr1, addr2, RCC, rcc;

    beforeEach(async function () {
        // 部署 RCC 代币合约
        RCC = await ethers.getContractFactory("ERC20Mock");
        console.log("Deploying ERC20Mock contract...");
        rcc = await RCC.deploy("RCC Token", "RCC", 18, ethers.parseEther("1000000"));
        // 等待交易确认并获取地址
        await rcc.deploymentTransaction().wait(); // 确保部署交易完成
        // 获取部署后的合约地址
        const rccAddress = await rcc.getAddress(); // 使用 await 解析 Promise
        console.log(`ERC20Mock deployed at: ${rccAddress}`);

        // 部署 RCCStake 合约
        RCCStake = await ethers.getContractFactory("RCCStake");
        console.log("Deploying RCCStake contract...");
        [owner, addr1, addr2] = await ethers.getSigners();
        rccStake = await RCCStake.deploy();
        await rccStake.deploymentTransaction().wait(); // 确保部署交易完成
        const rccStakeAddress = await rcc.getAddress(); // 使用 await 解析 Promise
        console.log(`RCCStake deployed at: ${rccStakeAddress}`);

        try {
            await rccStake.initialize(rccAddress, 0, 1000000, ethers.parseEther("1"));
            console.log("RCCStake initialized.");
        } catch (error) {
            console.error("Initialization failed:", error);
        }
    });

    it("Should set the correct RCC token address", async function () {
        // 检查 RCC 代币地址是否设置正确
        const currentRCCAddress = await rccStake.RCC();
        expect(currentRCCAddress).to.equal(await rcc.getAddress());
    });

    it("Should assign the correct roles to the deployer", async function () {
        // 检查合约部署者是否被赋予了正确的角色
        expect(await rccStake.hasRole(await rccStake.DEFAULT_ADMIN_ROLE(), owner.address)).to.be.true;
        expect(await rccStake.hasRole(await rccStake.UPGRADE_ROLE(), owner.address)).to.be.true;
    });

    it("Should allow admin to add a new staking pool", async function () {
        const currentBlockNumber = await ethers.provider.getBlockNumber();
    
        await expect(rccStake.connect(owner).addPool(ethers.ZeroAddress, 100, 0, 100, true))
            .to.emit(rccStake, "AddPool")
            .withArgs(
                ethers.ZeroAddress, 
                100, 
                currentBlockNumber + 1,  // 预期新块号可能为当前块号 + 1
                0, 
                100
            );
    });


    it("Should allow staking of tokens", async function () {
        // 添加第一个质押池，池子 ID 为 0
        await rccStake.connect(owner).addPool(ethers.ZeroAddress, 100, 0, 100, true);
    
        // 添加第二个质押池，池子 ID 为 1
        const mockToken = await ethers.getContractFactory("ERC20Mock");
        const token = await mockToken.deploy("Mock Token", "MTK", 18, ethers.parseUnits("1000000"));
        await token.waitForDeployment();
        await rccStake.connect(owner).addPool(token.target, 200, ethers.parseUnits("10"), 200, true);
    
        // 将代币转移到 addr1 并批准质押
        await token.transfer(addr1.address, ethers.parseEther("1000"));  // 确保转移的是 Mock Token
        
        // 授权足够的代币给 RCCStake 合约
        await token.connect(addr1).approve(await rccStake.getAddress(), ethers.parseEther("1000"));  // 授权的是 Mock Token
        
        // 使用正确的池子 ID 进行质押操作
        await rccStake.connect(addr1).deposit(1, ethers.parseEther("1000"));  // 使用池子 ID 1，对应 Mock Token
    
        // 检查用户的质押金额是否正确
        const userStake = await rccStake.stakingBalance(1,addr1.address);
        expect(userStake).to.equal(ethers.parseEther("1000"));

        // addr1 解除质押 500 RCC
        await rccStake.connect(addr1).unstake(1, ethers.parseEther("500"));
        // 检查用户的质押金额是否正确更新
        const userStake1 = await rccStake.stakingBalance(1,addr1.address);
        expect(userStake1).to.equal(ethers.parseEther("500"));


        // 通过人工增加块高或时间来模拟奖励积累
        await ethers.provider.send("evm_increaseTime", [3600]); // 模拟一个小时
        await ethers.provider.send("evm_mine"); // 挖一个区块

        // addr1 领取奖励
        await rccStake.connect(addr1).claim(1);

        // 检查领取后的状态
        const finalBalance = await rcc.balanceOf(addr1.address);
        console.log("User RCC balance after claim:", finalBalance);


        // 再次领取奖励，应该没有新增的奖励可领取
        await rccStake.connect(addr1).claim(1);
        const newBalance = await rcc.balanceOf(addr1.address);
        expect(newBalance).to.equal(finalBalance); // 确保余额没有变化
    });
    
});
