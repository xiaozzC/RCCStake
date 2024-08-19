const { buildModule } = require("@nomicfoundation/hardhat-ignition/modules");

module.exports = buildModule("RCCStakeModule", (m) => {
  // 这里设置默认参数，可以根据实际需求进行修改
  const RCC = m.getParameter("RCC", "0x8626f6940E2eb28930eFb4CeF49B2d1F2C9C1199"); // RCC 代币地址
  const startBlock = m.getParameter("startBlock", 1234567); // 开始区块号
  const endBlock = m.getParameter("endBlock", 2345678); // 结束区块号
  const RCCPerBlock = m.getParameter("RCCPerBlock", ethers.parseEther("0.1")); // 每个区块的 RCC 奖励

  // 部署 RCCStake 合约，并传入初始化参数
  const rccStake = m.contract("RCCStake", [], {
    afterDeploy: async () => {
      await rccStake.initialize(RCC, startBlock, endBlock, RCCPerBlock);
      console.log("RCCStake initialized with:", {
        RCC,
        startBlock,
        endBlock,
        RCCPerBlock: RCCPerBlock.toString(),
      });
    }
  });

  return { rccStake };
});
