import { ethers } from "hardhat";
import {
  CrocSwapDex,
  ColdPath,
  WarmPath,
  LongPath,
  MicroPaths,
  CrocPolicy,
  CrocQuery,
  HotPath,
  CrocImpact,
  HotProxy,
  KnockoutFlagPath,
  KnockoutLiqPath,
  MockERC20,
  SafeModePath,
} from "../../typechain";
import fs from "fs";

export async function sleep(ms: number) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

export async function contractWasDeployed(contract: string) {
  let code = await ethers.provider.getCode(contract);
  if (code.length > 2) {
    return true;
  }
  return false;
}

export async function writeContractsToFile(addrs: { [key: string]: string }) {
  await fs.writeFile(
    "misc/scripts/deployedContractAddresses.json",
    JSON.stringify(addrs, null, 2),
    (err) => {
      if (err) {
        console.error(err);
        return;
      }
    }
  );
}

export async function attachToContracts(addrs: { [key: string]: string }) {
  let factory;
  factory = await ethers.getContractFactory("CrocSwapDex");
  let dex = factory.attach(addrs.dex) as CrocSwapDex;

  factory = await ethers.getContractFactory("WarmPath");
  let warmPath = factory.attach(addrs.warmPath) as WarmPath;

  factory = await ethers.getContractFactory("LongPath");
  let longPath = factory.attach(addrs.longPath) as LongPath;

  factory = await ethers.getContractFactory("MicroPaths");
  let microPath = factory.attach(addrs.microPath) as MicroPaths;

  factory = await ethers.getContractFactory("ColdPath");
  let coldPath = factory.attach(addrs.coldPath) as ColdPath;

  factory = await ethers.getContractFactory("HotProxy");
  let hotPath = factory.attach(addrs.hotProxy) as HotProxy;

  factory = await ethers.getContractFactory("KnockoutLiqPath");
  let knockoutLiqPath = factory.attach(
    addrs.knockoutLiqPath
  ) as KnockoutLiqPath;

  factory = await ethers.getContractFactory("KnockoutFlagPath");
  let knockoutFlagPath = factory.attach(
    addrs.knockoutFlagPath
  ) as KnockoutFlagPath;

  factory = await ethers.getContractFactory("SafeModePath");
  let safeModePath = factory.attach(addrs.safeModePath) as SafeModePath;

  // Governance contract

  factory = await ethers.getContractFactory("CrocPolicy");
  let policy = factory.attach(addrs.policy) as CrocPolicy;

  // Lens contracts (Query and Impact) do not change the dex, but reveal useful information about swaps

  factory = await ethers.getContractFactory("CrocQuery");
  let query = factory.attach(addrs.query) as CrocQuery;

  factory = await ethers.getContractFactory("CrocImpact");
  let impact = factory.attach(addrs.impact) as CrocImpact;

  return {
    dex,
    warmPath,
    longPath,
    microPath,
    coldPath,
    hotPath,
    knockoutLiqPath,
    knockoutFlagPath,
    safeModePath,
    policy,
    query,
    impact,
  };
}
