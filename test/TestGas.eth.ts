import { TestPool, makeTokenPool, Token, makeEtherPool } from './FacadePool'
import { expect } from "chai";
import "@nomiclabs/hardhat-ethers";
import { ethers } from 'hardhat';
import { toSqrtPrice, fromSqrtPrice, maxSqrtPrice, minSqrtPrice } from './FixedPoint';
import { solidity } from "ethereum-waffle";
import chai from "chai";
import { MockERC20 } from '../typechain/MockERC20';
import { ContractTransaction, BigNumber } from 'ethers';

chai.use(solidity);

// If set to true, every test will fail and therefore print the actual gas spend. 
const METRIC_PROFILE = false

describe('Gas Benchmarks Native Eth', () => {
    let test: TestPool
    let initTx: Promise<ContractTransaction>
    const feeRate = 225 * 100

    beforeEach("deploy",  async () => {
       test = await makeEtherPool()
       await test.fundTokens()

       initTx = test.initPool(feeRate, 0, 1, 1.0)
       await initTx

       test.useHotPath = true
    })

    async function gasUsed (tx: Promise<ContractTransaction>): Promise<BigNumber> {
        return tx
            .then(t => t.wait())
            .then(t => t.gasUsed)
    }

    async function expectGas (tx: Promise<ContractTransaction>, limit: number) {
        let gas = await gasUsed(tx)
        let comp = METRIC_PROFILE ? 0 : limit
        expect(gas).to.be.lt(comp)
    }

    it("mint in virgin pool [@gas-test]", async() => {
        await expectGas(test.testMint(-100, 100, 100), 309000)
    })

    it("mint increase liq [@gas-test]", async() => {
        await test.testMint(-100, 100, 100)
        await expectGas(test.testMint(-100, 100, 10000), 116000)
    })

    it("mint pre-init ticks [@gas-test]", async() => {
        await test.testMint(-100, 100, 100)
        await expectGas(test.testMintOther(-100, 100, 10000), 151000)
    })

    it("mint one fresh init [@gas-test]", async() => {
        await test.testMint(-100, 100, 100)
        await expectGas(test.testMintOther(-100, 200, 10000), 176000)
    })

    it("mint fresh ticks [@gas-test]", async() => {
        await test.testMint(-100, 100, 100)
        await expectGas(test.testMintOther(-200, 200, 10000), 201000)
    })

    it("mint below price [@gas-test]", async() => {
        await test.testMint(-100, 100, 100)
        await expectGas(test.testMintOther(-300, -200, 10000), 194000)
    })

    it("mint above price [@gas-test]", async() => {
        await test.testMint(-100, 100, 100)
        await expectGas(test.testMintOther(200, 300, 100), 216000)
    })

    it("burn partial [@gas-test]", async() => {
        await test.testMint(-100, 100, 100)
        await expectGas(test.testBurn(-100, 100, 50), 146500)
    })

    it("burn partial level left [@gas-test]", async() => {
        await test.testMint(-100, 100, 100)
        await test.testMintOther(-100, 100, 100)
        await expectGas(test.testBurn(-100, 100, 50), 146500)
    })

    it("burn full [@gas-test]", async() => {
        await test.testMint(-100, 100, 100)
        await expectGas(test.testBurn(-100, 100, 100), 138000)
    })

    it("burn full level left [@gas-test]", async() => {
        await test.testMint(-100, 100, 100)
        await test.testMintOther(-100, 100, 100)
        await expectGas(test.testBurn(-100, 100, 100), 141500)
    })

    it("burn outside [@gas-test]", async() => {
        await test.testMint(-200, -100, 100)
        await expectGas(test.testBurn(-200, -100, 100), 116000)
    })

    it("burn outside left [@gas-test]", async() => {
        await test.testMint(-200, -100, 100)
        await test.testMintOther(-200, -100, 100)
        await expectGas(test.testBurn(-200, -100, 100), 122500)
    })

    it("burn liq rewards [@gas-test]", async() => {
        await test.testMint(-100, 100, 100000)
        await test.testSwapOther(true, true, 1000, toSqrtPrice(1.1))
        await expectGas(test.testBurn(-100, 100, 100), 147000)
    })

    it("burn liq level left [@gas-test]", async() => {
        await test.testMint(-100, 100, 100)
        await test.testMintOther(-100, 100, 100)
        await test.testSwapOther(true, true, 1000, toSqrtPrice(1.1))
        await expectGas(test.testBurn(-100, 100, 100), 165500)
    })

    it("burn flipped [@gas-test]", async() => {
        await test.testMint(-100, 100, 100)
        await test.testSwapOther(true, true, 1000000, toSqrtPrice(1.1))
        await expectGas(test.testBurn(-100, 100, 100), 156500)
    })

    it("burn flipped level left [@gas-test]", async() => {
        await test.testMint(-100, 100, 100)
        await test.testMintOther(-100, 100, 1000)
        await test.testSwapOther(true, true, 1000000, toSqrtPrice(1.1))
        await expectGas(test.testBurn(-100, 100, 100), 162500)
    })

    it("harvest fees [@gas-test]", async() => {
        await test.testMint(-100, 100, 100)
        await test.testMintOther(-100, 100, 1000)
        await test.testSwapOther(true, true, 1000000, toSqrtPrice(1.1))
        await test.testSwapOther(false, true, 1000000, toSqrtPrice(1.0))
        await expectGas(test.testHarvest(-100, 100), 113000)
    })

    it("swap no pre-warm [@gas-test]", async() => {
        await test.testMint(-100, 100, 10000)
        await expectGas(test.testSwapOther(true, true, 1000, toSqrtPrice(1.1)), 113000)
        expect(await test.liquidity()).to.be.gt(10000*1024)
    })

    it("swap small [@gas-test]", async() => {
        await test.testMint(-100, 100, 10000)
        await test.testSwapOther(true, true, 1000, toSqrtPrice(1.1))
        await expectGas(test.testSwapOther(true, true, 1000, toSqrtPrice(1.1)), 96000)
        expect(await test.liquidity()).to.be.gt(10000*1024)
    })

    it("swap small [@gas-test]", async() => {
        await test.testMint(-100, 100, 10000)
        await test.testSwapOther(true, true, 1000, toSqrtPrice(1.1))
        await expectGas(test.testSwapOther(true, true, 1000, toSqrtPrice(1.1)), 96000)
        expect(await test.liquidity()).to.be.gt(10000*1024)
    })

    it("swap small sell [@gas-test]", async() => {
        await test.testMint(-100, 100, 10000)
        await test.testSwapOther(false, true, 1000, toSqrtPrice(0.9))
        await expectGas(test.testSwapOther(true, true, 1000, toSqrtPrice(1.1)), 95000)
        expect(await test.liquidity()).to.be.gt(10000*1024)
    })

    it("swap tick w/o cross [@gas-test]", async() => {
        await test.testMint(-100, 100, 10000)
        await test.testSwapOther(true, true, 1000, toSqrtPrice(1.0005))
        await expectGas(test.testSwapOther(true, true, 10000000, toSqrtPrice(1.005)), 106000)
        expect(await test.liquidity()).to.be.gt(10000*1024)
    })

    it("swap bitmap w/o cross [@gas-test]", async() => {
        await test.testMint(-500, 500, 10000)
        await test.testSwapOther(true, true, 1000, toSqrtPrice(1.1))
        await expectGas(test.testSwapOther(true, true, 10000000, toSqrtPrice(1.04)), 110000)
        expect(await test.liquidity()).to.be.gt(10000*1024)
    })

    it("swap cross tick [@gas-test]", async() => {
        await test.testMint(-100, 100, 10000)
        await test.testMint(-500, 500, 10000)
        await test.testSwapOther(true, true, 1000, toSqrtPrice(1.1))
        await expectGas(test.testSwapOther(true, true, 1000000, toSqrtPrice(1.04)), 129000)
        expect(await test.liquidity()).to.be.lt(10100*1024)
        expect(await test.liquidity()).to.be.gt(10000*1024)
    })

    it("swap cross two tick [@gas-test]", async() => {
        await test.testMint(-100, 100, 10000)
        await test.testMint(-200, 200, 10000)
        await test.testMint(-500, 500, 10000)
        await test.testSwapOther(true, true, 1000, toSqrtPrice(1.1))

        await expectGas(test.testSwapOther(true, true, 2000000, toSqrtPrice(1.021)), 134000)
        expect(await test.liquidity()).to.be.lt(10100*1024)
        expect(await test.liquidity()).to.be.gt(10000*1024)
    })

    it("swap cross two tick and bitmap [@gas-test]", async() => {
        await test.testMint(-100, 100, 10000)
        await test.testMint(-200, 200, 10000)
        await test.testMint(-500, 500, 10000)
        await test.testSwapOther(true, true, 1000, toSqrtPrice(1.1))

        await expectGas(test.testSwapOther(true, true, 2000000, toSqrtPrice(1.04)), 148000)
        expect(await test.liquidity()).to.be.lt(10100*1024)
        expect(await test.liquidity()).to.be.gt(10000*1024)
    })

    it("swap cross bitmap between two tick  [@gas-test]", async() => {
        await test.testMint(-100, 100, 10000)
        await test.testMint(-200, 300, 10000)
        await test.testMint(-500, 500, 10000)
        await test.testSwapOther(true, true, 1000, toSqrtPrice(1.1))

        await expectGas(test.testSwapOther(true, true, 2000000, toSqrtPrice(1.04)), 148000)
        expect(await test.liquidity()).to.be.lt(10100*1024)
        expect(await test.liquidity()).to.be.gt(10000*1024)
    })

    it("swap cross many ticks [@gas-test]", async() => {
        await test.testMint(-100, 100, 10000)
        await test.testMint(-200, 200, 1000)
        await test.testMint(-200, 210, 1000)
        await test.testMint(-200, 220, 1000)
        await test.testMint(-200, 250, 1000)
        await test.testMint(-200, 280, 1000)
        await test.testMint(-200, 300, 1000)
        await test.testMint(-500, 500, 1000)
        await test.testSwapOther(true, true, 1000, toSqrtPrice(1.1))

        await expectGas(test.testSwapOther(true, true, 2000000, toSqrtPrice(1.04)), 260000)
        expect(await test.liquidity()).to.be.lt(1010*1024)
        expect(await test.liquidity()).to.be.gt(1000*1024)
    })

    it("swap cross many bitmap [@gas-test]", async() => {
        await test.testMint(-10000, 100000, 10000)
        await test.testSwapOther(true, true, 100000000, toSqrtPrice(5.0))

        await expectGas(test.testSwapOther(true, true, 2000000, toSqrtPrice(1050.0)), 119000)
        expect(fromSqrtPrice(await test.price())).gt(2.4)
    })

})
