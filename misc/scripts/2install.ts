import { ethers } from "hardhat";
import { BigNumber } from "ethers";
import { ZERO_ADDR } from "../../test/FixedPoint";

import addresses from "./deployedContractAddresses.json";
import fs from "fs";
import { attachToContracts } from "./utils";

let override = {
  gasPrice: BigNumber.from("10").pow(9).mul(4),
  gasLimit: 10000000,
};

async function install() {
  let authority = (await ethers.getSigners())[0];

  let abi = new ethers.utils.AbiCoder();
  let cmd;
  let tx;
  let receipt;

  let {
    dex,
    coldPath,
    warmPath,
    longPath,
    microPath,
    hotPath,
    knockoutLiqPath,
    knockoutFlagPath,
    safeModePath,
    policy,
    query,
    impact,
  } = await attachToContracts(addresses);

  const BOOT_PROXY_IDX = 0;
  const SWAP_PROXY_IDX = 1;
  const LP_PROXY_IDX = 2;
  const COLD_PROXY_IDX = 3;
  const LONG_PROXY_IDX = 4;
  const MICRO_PROXY_IDX = 5;
  const KNOCKOUT_LP_PROXY_IDX = 7;
  const FLAG_CROSS_PROXY_IDX = 3500;
  const SAFE_MODE_PROXY_PATH = 9999;

  // use protocolCmd to install paths
  // install coldpath
  console.log("Installing ColdPath");
  cmd = abi.encode(
    ["uint8", "address", "uint16"],
    [21, coldPath.address, COLD_PROXY_IDX]
  );
  tx = await dex.protocolCmd(BOOT_PROXY_IDX, cmd, true);
  receipt = await tx.wait();

  // // install longpath
  console.log("Installing LongPath");
  cmd = abi.encode(
    ["uint8", "address", "uint16"],
    [21, longPath.address, LONG_PROXY_IDX]
  );
  tx = await dex.protocolCmd(BOOT_PROXY_IDX, cmd, true);
  receipt = await tx.wait();

  // // install warm path
  console.log("Installing WarmPath");
  cmd = abi.encode(
    ["uint8", "address", "uint16"],
    [21, warmPath.address, LP_PROXY_IDX]
  );
  tx = await dex.protocolCmd(BOOT_PROXY_IDX, cmd, true);
  receipt = await tx.wait();

  // // install hot proxy path
  console.log("Installing HotPath Proxy");
  cmd = abi.encode(
    ["uint8", "address", "uint16"],
    [21, hotPath.address, SWAP_PROXY_IDX]
  );
  tx = await dex.protocolCmd(BOOT_PROXY_IDX, cmd, true);
  receipt = await tx.wait();

  // // install micro paths
  console.log("Installing MicroPaths");
  cmd = abi.encode(
    ["uint8", "address", "uint16"],
    [21, microPath.address, MICRO_PROXY_IDX]
  );
  tx = await dex.protocolCmd(BOOT_PROXY_IDX, cmd, true);
  receipt = await tx.wait();

  // // install knockout lp proxy path
  console.log("Installing KnockoutLiqPath");
  cmd = abi.encode(
    ["uint8", "address", "uint16"],
    [21, knockoutLiqPath.address, KNOCKOUT_LP_PROXY_IDX]
  );
  tx = await dex.protocolCmd(BOOT_PROXY_IDX, cmd, true);
  receipt = await tx.wait();

  // // install cross knockout cross proxy path
  console.log("Installing KnockoutFlagPath");
  cmd = abi.encode(
    ["uint8", "address", "uint16"],
    [21, knockoutFlagPath.address, FLAG_CROSS_PROXY_IDX]
  );
  tx = await dex.protocolCmd(BOOT_PROXY_IDX, cmd, true);
  receipt = await tx.wait();

  // // install safe mode path
  console.log("Installing SafeModePath");
  cmd = abi.encode(
    ["uint8", "address", "uint16"],
    [21, safeModePath.address, SAFE_MODE_PROXY_PATH]
  );
  tx = await dex.protocolCmd(BOOT_PROXY_IDX, cmd, true);
  receipt = await tx.wait();
}

install().then(
  () => {
    process.exit(0);
  },
  (err) => {
    console.log("FAILURE", err);
    process.exit(0);
  }
);
