import { ethers } from "hardhat";
import { BigNumber } from "ethers";
import { ZERO_ADDR } from "../../test/FixedPoint";
import { CrocSwapDex } from "../../typechain/CrocSwapDex";
import { ColdPath } from "../../typechain/ColdPath";
import { WarmPath } from "../../typechain/WarmPath";
import { LongPath } from "../../typechain/LongPath";
import { MicroPaths } from "../../typechain/MicroPaths";
import { CrocPolicy } from "../../typechain/CrocPolicy";
import { CrocQuery } from "../../typechain/CrocQuery";
import { HotPath } from "../../typechain/HotPath";
import {
  CrocImpact,
  HotProxy,
  KnockoutFlagPath,
  KnockoutLiqPath,
  MockERC20,
  SafeModePath,
} from "../../typechain";
import { sleep, contractWasDeployed, writeContractsToFile } from "./utils";

let override = {
  gasPrice: BigNumber.from("10").pow(9).mul(4),
  gasLimit: 10000000,
};

let undefined_addrs = {
  dex: undefined,
  cold: undefined,
  warm: undefined,
  long: undefined,
  micro: undefined,
  hot: undefined,
  knockout: undefined,
  koCross: undefined,
  safeMode: undefined,
  policy: undefined,
  query: undefined,
  impact: undefined,
  shell: undefined,
};

let testnet_addrs = {
  warm: "0x0De7ad8558621ea17d9422d814D7DC7190dcf6C6",
  cold: "0x3D864204f4cFa8492e9c3c3d729EAa200347fE1F",
  long: "0x598d730ba1caa630a580cE7Dd9C9DF724409D8a4",
  micro: "0x6aC0702e74c6f4Cb12333ba99682B3Fa25930EEe",
  hot: "0x2360533f7fC69491873246d05c4BbA794A978fC1",
  safeMode: "0x8E5D4D5B2b9FE23fB814eAdBEA2191AA5e9B5e8B",
  knockout: "0x714Ad6A4C479A057F87008CA39E8897D8b327A29",
  koCross: "0x7B36D0e14A8021986fc5722bBFc58eF8f5262856",
  dex: "0xEC02F954b2Bd3B196f42a387275C6C40459a72fE",
  policy: "0x90D2bA9bD445aF7f907Df844Eda05A92c1cffE72",
  query: "0xe844d8Ac349979be34140d5f97052166f0a671C6",
  impact: "0x4b05Bf59F41aD3412384256b4bfdD3b836D722FD",
};

let tokens = {
  althea: ZERO_ADDR,
  dai: "0x0412C7c846bb6b7DC462CF6B453f76D8440b2609",
  usdc: "0x30dA8589BFa1E509A319489E014d384b87815D89",
};

async function deploy() {
  let authority = (await ethers.getSigners())[0];

  let abi = new ethers.utils.AbiCoder();
  let cmd;
  let factory;
  let tx;

  // Simple switch for the addresses to use - undefined to force deployment
  // or use the testnet_addrs to use previously deployed contracts
  let addrs = undefined_addrs;

  // Deploy all the DEX contracts (core DEX + extra code paths + periphery)

  console.log("Deploying with the following addresses...");
  console.log("Protocol Authority: ", await authority.address);

  console.log("DEX");
  factory = await ethers.getContractFactory("CrocSwapDex");
  let dex = (await factory.deploy(override)) as CrocSwapDex;

  console.log("Warmpath");
  factory = await ethers.getContractFactory("WarmPath");
  let warmPath = (await factory.deploy(override)) as WarmPath;

  console.log("Longpath");
  factory = await ethers.getContractFactory("LongPath");
  let longPath = (await factory.deploy(override)) as LongPath;

  console.log("Micropath");
  factory = await ethers.getContractFactory("MicroPaths");
  let microPath = (await factory.deploy(override)) as MicroPaths;

  console.log("Coldpath");
  factory = await ethers.getContractFactory("ColdPath");
  let coldPath = (await factory.deploy(override)) as ColdPath;

  console.log("Hotproxy");
  factory = await ethers.getContractFactory("HotProxy");
  let hotProxy = (await factory.deploy(override)) as HotProxy;

  console.log("KnockoutLiqpath");
  factory = await ethers.getContractFactory("KnockoutLiqPath");
  let knockoutLiqPath = (await factory.deploy(override)) as KnockoutLiqPath;

  console.log("KnockoutFlagpath");
  factory = await ethers.getContractFactory("KnockoutFlagPath");
  let knockoutFlagPath = (await factory.deploy(override)) as KnockoutFlagPath;

  console.log("SafeModepath");
  factory = await ethers.getContractFactory("SafeModePath");
  let safeModePath = (await factory.deploy(override)) as SafeModePath;

  // Governance contract

  console.log("Policy");
  factory = await ethers.getContractFactory("CrocPolicy");
  let policy = (await factory.deploy(dex.address, override)) as CrocPolicy;

  // Lens contracts (Query and Impact) do not change the dex, but reveal useful information about swaps

  console.log("Query");
  factory = await ethers.getContractFactory("CrocQuery");
  let query = (await factory.deploy(
    dex.address,
    override
  )) as CrocQuery as CrocQuery;

  console.log("Impact");
  factory = await ethers.getContractFactory("CrocImpact");
  let impact = (await factory.deploy(
    dex.address,
    override
  )) as CrocImpact as CrocImpact;

  const contracts = {
    warmPath: warmPath.address,
    coldPath: coldPath.address,
    longPath: longPath.address,
    microPath: microPath.address,
    hotProxy: hotProxy.address,
    safeModePath: safeModePath.address,
    knockoutLiqPath: knockoutLiqPath.address,
    knockoutFlagPath: knockoutFlagPath.address,
    dex: dex.address,
    policy: policy.address,
    query: query.address,
    impact: impact.address,
  };
  console.log(contracts);
  await writeContractsToFile(contracts);

  await sleep(5000);

  console.log("Deploy status: ", {
    warmPath: await contractWasDeployed(warmPath.address),
    coldPath: await contractWasDeployed(coldPath.address),
    longPath: await contractWasDeployed(longPath.address),
    microPath: await contractWasDeployed(microPath.address),
    hotProxy: await contractWasDeployed(hotProxy.address),
    safeModePath: await contractWasDeployed(safeModePath.address),
    knockoutLiqPath: await contractWasDeployed(knockoutLiqPath.address),
    knockoutFlagPath: await contractWasDeployed(knockoutFlagPath.address),
    dex: await contractWasDeployed(dex.address),
    policy: await contractWasDeployed(policy.address),
    query: await contractWasDeployed(query.address),
    impact: await contractWasDeployed(impact.address),
  });

  // // -----------------------------
  // // EXTRA FUNCTIONS
  // // -----------------------------
  // // set protocol take rate
  // console.log("Setting protocol take rate to 0");
  // let takeRateCmd = abi.encode(["uint8", "uint16"], [114, 0]);
  // tx = await dex.protocolCmd(3, takeRateCmd, true);
  // await tx.wait();
  // console.log("Protocol take rate set: ", tx);

  // // set relayer take rate
  // console.log("Setting relayer take rate to 0");
  // let relayerTakeRateCmd = abi.encode(["uint8", "uint16"], [116, 0]);
  // tx = await dex.protocolCmd(3, relayerTakeRateCmd, true);
  // await tx.wait();
  // console.log("Relayer take rate set: ", tx);

  // console.log("Successfully deployed and initialized DEX contracts");

  // Miscellaneous commands that may or may not be correctly configured/called
  // some of these are from the canto deploy scripts and some are outdated comments
  // from the CrocSwap-protocol repo

  // // deposit surplus USDC and cNOTE into pool
  // let depositSurplusUSDCCmd = abi.encode(
  // 	["uint8", "address", "uint128", "address"],
  // 	[73, "0xEf109EF4969261eB92A9F00d6639b440160Cc237", 100000, usdcAddress]
  // );
  // tx = await dex.userCmd(3, depositSurplusUSDCCmd);
  // let depositSurpluNOTECmd = abi.encode(
  // 	["uint8", "address", "uint128", "address"],
  // 	[
  // 		73,
  // 		"0xEf109EF4969261eB92A9F00d6639b440160Cc237",
  // 		1000000000000,
  // 		cNoteAddress,
  // 	]
  // );
  // tx = await dex.userCmd(3, depositSurpluNOTECmd);

  /*tx = await dai.approve(dex.address, BigNumber.from(10).pow(36))
    await tx.wait()

    tx = await usdc.approve(dex.address, BigNumber.from(10).pow(36))
    await tx.wait()*/

  /*let authCmd = abi.encode(["uint8", "address"], [20, policy.address])
    tx = await dex.protocolCmd(0, authCmd, true, override);
    await tx.wait()

    let upCmd = abi.encode(["uint8", "address", "uint16"], [21, warmPath.address, 2])
    tx = await policy.treasuryResolution(dex.address, 0, upCmd, true, override);
    await tx.wait()

    upCmd = abi.encode(["uint8", "address", "uint16"], [21, longPath.address, 4])
    tx = await policy.treasuryResolution(dex.address, 0, upCmd, true, override);
    await tx.wait()

    upCmd = abi.encode(["uint8", "address", "uint16"], [21, microPath.address, 5])
    tx = await policy.treasuryResolution(dex.address, 0, upCmd, true, override);
    await tx.wait() 

    let upCmd = abi.encode(["uint8", "address", "uint16"], [21, knockoutPath.address, 7])
    tx = await policy.treasuryResolution(dex.address, 0, upCmd, true, override);
    await tx.wait()

    upCmd = abi.encode(["uint8", "address", "uint16"], [21, crossPath.address, 3500])
    tx = await policy.treasuryResolution(dex.address, 0, upCmd, true, override);
    await tx.wait()*/

  /*let setPoolLiqCmd = abi.encode(["uint8", "uint128"], [112, 10000])
    tx = await policy.treasuryResolution(dex.address, 0, setPoolLiqCmd, false)
    await tx.wait()

    let templateCmd = abi.encode(["uint8", "uint256", "uint16", "uint16", "uint8", "uint8", "uint8"],
        [110, 36000, 500, 64, 5, 64, 0])
    tx = await policy.opsResolution(dex.address, 0, templateCmd)
    await tx.wait()

    return*/

  /*console.log("Q")
    let initPoolCmd = abi.encode(["uint8", "address", "address", "uint256", "uint128"],
        [71, tokens.eth, tokens.dai, 36000, toSqrtPrice(1/3000)])
    tx = await dex.userCmd(0, initPoolCmd, { value: BigNumber.from(10).pow(15), gasLimit: 6000000})
    console.log(tx)
    await tx.wait()

    let initUsdcCmd = abi.encode(["uint8", "address", "address", "uint256", "uint128"],
        [71, tokens.usdc, tokens.dai, 36000, toSqrtPrice(Math.pow(10, -12))])
    tx = await dex.userCmd(0, initUsdcCmd, { gasLimit: 6000000})
    console.log(tx)
    await tx.wait()*/

  // Enable knockout liquidity
  /*const knockoutFlag = 32 + 6 // Enabled, on grid, 32-ticks wide
    let reviseCmd = abi.encode(["uint8", "address", "address", "uint256", "uint16", "uint16", "uint8", "uint8"],
        [111, tokens.eth, tokens.dai, 36000, 1000, 64, 5, knockoutFlag])
    tx = await policy.treasuryResolution(dex.address, 0, reviseCmd, false)
    await tx.wait()*/

  /*reviseCmd = abi.encode(["uint8", "address", "address", "uint256", "uint16", "uint16", "uint8", "uint8"],
        [111, tokens.eth, tokens.usdc, 36000, 500, 64, 5, knockoutFlag])
    tx = await policy.treasuryResolution(dex.address, 0, reviseCmd, false)
    await tx.wait()

    reviseCmd = abi.encode(["uint8", "address", "address", "uint256", "uint16", "uint16", "uint8", "uint8"],
        [111, tokens.usdc, tokens.dai, 36000, 500, 64, 5, knockoutFlag])
    tx = await policy.treasuryResolution(dex.address, 0, reviseCmd, false)
    await tx.wait()*/

  /*let mintCmd = abi.encode(["uint8", "address", "address", "uint256", "int24", "int24", "uint128", "uint128", "uint128", "uint8", "address"],
        [31, tokens.eth, tokens.dai, 36000, 0, 0, BigNumber.from(10).pow(15), MIN_PRICE, MAX_PRICE, 0, ZERO_ADDR ])
    tx = await dex.userCmd(2, mintCmd, { value: BigNumber.from(10).pow(15), gasLimit: 6000000})
    console.log(tx)
    await tx.wait()*/

  /*cmd = abi.encode(["uint8", "address", "address", "uint256", "int24", "int24", "uint128", "uint128", "uint128", "uint8", "address"],
        [31, tokens.usdc, tokens.dai, 36000, 0, 0, BigNumber.from(10).pow(3), MIN_PRICE, MAX_PRICE, 0, ZERO_ADDR ])
    tx = await dex.userCmd(2, cmd, { gasLimit: 6000000})
    console.log(tx)
    await tx.wait()*/

  /*tx = await dex.swap(tokens.eth, tokens.dai, 36000, true, true, BigNumber.from(10).pow(12), 0, MAX_PRICE, 0, 0,
        {value: BigNumber.from(10).pow(12)})
    await tx.wait()

    tx = await dex.swap(tokens.eth, tokens.dai, 36000, false, true, BigNumber.from(10).pow(12), 0, MIN_PRICE, 0, 0)
    await tx.wait()*/

  /*tx = await dex.swap(tokens.dai, tokens.usdc, 36000, true, false, BigNumber.from(10).pow(2), 0, MAX_PRICE, 0, 0)
    await tx.wait()*/

  // Burn ambient
  /*cmd = abi.encode(["uint8", "address", "address", "uint256", "int24", "int24", "uint128", "uint128", "uint128", "uint8", "address"],
        [41, tokens.eth, tokens.dai, 36000, 0, 0, BigNumber.from(10).pow(15), MIN_PRICE, MAX_PRICE, 0, ZERO_ADDR ])
    tx = await dex.userCmd(2, cmd, {gasLimit: 6000000})
    await tx.wait()*/

  // Remint
  /*cmd = abi.encode(["uint8", "address", "address", "uint256", "int24", "int24", "uint128", "uint128", "uint128", "uint8", "address"],
        [31, tokens.eth, tokens.dai, 36000, 0, 0, BigNumber.from(10).pow(15), MIN_PRICE, MAX_PRICE, 0, ZERO_ADDR ])
    tx = await dex.userCmd(2, cmd, {gasLimit: 6000000, value: BigNumber.from(10).pow(15) })
    console.log(tx)
    await tx.wait()*/

  // Mint concentrated liquidity
  /*cmd = abi.encode(["uint8", "address", "address", "uint256", "int24", "int24", "uint128", "uint128", "uint128", "uint8", "address"],
        [11, tokens.eth, tokens.dai, 36000, -128000+256, 128000-256, BigNumber.from(10).pow(15), MIN_PRICE, MAX_PRICE, 0, ZERO_ADDR ])
    tx = await dex.userCmd(2, cmd, {gasLimit: 6000000, value: BigNumber.from(10).pow(15) })
    console.log(tx)
    await tx.wait()*/

  /*cmd = abi.encode(["uint8", "address", "address", "uint256", "int24", "int24", "uint128", "uint128", "uint128", "uint8", "address"],
        [21, tokens.eth, tokens.dai, 36000, -128000+64, 128000-64, BigNumber.from(10).pow(15), MIN_PRICE, MAX_PRICE, 0, ZERO_ADDR ])
    tx = await dex.userCmd(2, cmd, {gasLimit: 6000000, value: BigNumber.from(10).pow(16) })
    console.log(tx)
    await tx.wait()*/
}

deploy().then(
  () => {
    process.exit(0);
  },
  (err) => {
    console.log("FAILURE", err);
    process.exit(0);
  }
);
