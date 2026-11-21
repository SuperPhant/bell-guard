import { existsSync, readFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import {
  createPublicClient,
  createWalletClient,
  http,
  parseAbi,
  type Address,
  type Hash,
  type Hex,
  type Log,
  type TransactionReceipt,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { baseSepolia } from "viem/chains";

const here = dirname(fileURLToPath(import.meta.url));
export const root = resolve(here, "..", "..");

export type BaseDeployment = {
  chainId: number;
  deployer: Address;
  reactive: Address;
  callbackProxy: Address;
  guard: Address;
  liveMarket: Address;
  sandboxMarket: Address;
  sandboxHub: Address;
  crashLab: Address;
  usd: Address;
  tsla: Address;
  mstr: Address;
  nvda: Address;
  sandboxStartPrice: number;
  startBlock: number;
  liveBorrower?: Address;
};

export const deployment: BaseDeployment = JSON.parse(
  readFileSync(resolve(root, "contracts/deployments/84532.json"), "utf8"),
);
const lasnaFile = resolve(root, "contracts/deployments/5318007.json");
export const lasnaDeployment: { reactive: Address; deployTx: Hash } | undefined = existsSync(lasnaFile)
  ? JSON.parse(readFileSync(lasnaFile, "utf8"))
  : undefined;

export const BASE_RPC = process.env.BASE_SEPOLIA_RPC ?? "https://sepolia.base.org";
/** sepolia.base.org caps eth_getLogs at 200 blocks (40 s), so log scans use a node that allows wide ranges. */
export const BASE_LOGS_RPC = process.env.BASE_SEPOLIA_LOGS_RPC ?? "https://base-sepolia-rpc.publicnode.com";
export const BASE_TIME: Address = "0x4200000000000000000000000000000000000030";
export const BLOCK_MS = 200;

export const pub = createPublicClient({ chain: baseSepolia, transport: http(BASE_RPC), pollingInterval: 100 });
export const logsPub = createPublicClient({ chain: baseSepolia, transport: http(BASE_LOGS_RPC) });

export function wallet() {
  const key = process.env.DEPLOYER_KEY as Hex | undefined;
  if (!key) throw new Error("DEPLOYER_KEY is not set");
  return createWalletClient({ account: privateKeyToAccount(key), chain: baseSepolia, transport: http(BASE_RPC) });
}

export const labAbi = parseAbi([
  "function print(address token, int256 answer) returns (uint64)",
  "function openPair(address token, uint256 units, uint256 reserve) returns (uint256)",
  "function arm(uint256 pairId, uint64 triggerHf, uint64 targetHf, uint128 budget)",
  "function confirmAndLiquidate(uint256 pairId, int256 answer)",
  "function disarm(uint256 pairId)",
  "function newBorrower() returns (address)",
  "function act(address b, address target, bytes data) returns (bytes)",
  "function mint(address token, address to, uint256 amount)",
  "function round() view returns (uint80)",
  "function pairOf(uint256 pairId) view returns ((address token, address guarded, address unguarded))",
  "event Printed(address indexed token, uint80 roundId, int256 answer, uint64 atMs)",
  "event PairOpened(uint256 indexed pairId, address indexed token, address guarded, address unguarded, uint256 units, uint256 debt)",
  "event LiquidationAttempt(uint256 indexed pairId, address indexed account, bool liquidated, uint256 healthBefore, uint256 repaid, uint256 seized, uint64 atMs)",
  "event BorrowerCreated(address indexed borrower)",
]);

export const guardAbi = parseAbi([
  "function protect(address market, uint64 triggerHf, uint64 targetHf, uint128 budget)",
  "function protectionOf(address market, address account) view returns (uint64 triggerHf, uint64 targetHf, uint128 budget, uint128 spent)",
  "function accountsOf(address market) view returns (address[])",
  "function pessimisticHealthOf(address market, address account) view returns (uint256)",
  "function printsHandled() view returns (uint256)",
  "function rescues() view returns (uint256)",
  "event PrintHandled(address indexed market, address indexed token, uint80 roundId, int256 prevAnswer, int256 answer, uint256 originBlock, uint256 reactiveBlock, uint256 reactiveTimestamp, uint64 handledAtMs, uint256 checked, uint256 rescued)",
  "event Guarded(address indexed market, address indexed account, address indexed token, uint80 roundId, uint256 repaid, uint256 healthBefore, uint256 healthAfter)",
  "event GuardFailed(address indexed market, address indexed account, uint80 roundId, uint256 wanted, bytes reason)",
  "event SweepPaused(address indexed market, address indexed token, uint80 roundId, int256 prevAnswer, int256 answer, uint256 originBlock, uint256 nextIndex)",
]);

export const marketAbi = parseAbi([
  "function observationOf(address token) view returns (uint80 lastRound, uint80 prevRound, int256 lastAnswer, int256 prevAnswer)",
  "function healthFactorOf(address account) view returns (uint256)",
  "function debtOf(address account) view returns (uint256)",
  "function borrowPowerOf(address account) view returns (uint256)",
  "function collateralOf(address account, address token) view returns (uint256)",
  "function depositCollateral(address token, uint256 amount)",
  "function borrow(uint256 amount)",
  "event Observed(address indexed token, uint80 roundId, int256 answer)",
]);

export const tokenAbi = parseAbi([
  "function approve(address spender, uint256 amount) returns (bool)",
  "function balanceOf(address account) view returns (uint256)",
]);

export const timeAbi = parseAbi(["function timestampMs() view returns (uint64)"]);

/** Millisecond timestamp of a Base block, from the BaseTime predeploy's state after that block. If the node has
 *  pruned that state, it is derived from a recent anchor: Base Sepolia blocks are exactly 200 ms apart. */
let anchor: { block: bigint; ms: bigint } | undefined;
export async function blockMs(blockNumber: bigint): Promise<bigint> {
  try {
    return await pub.readContract({ address: BASE_TIME, abi: timeAbi, functionName: "timestampMs", blockNumber });
  } catch {
    if (!anchor) {
      const block = await pub.getBlockNumber();
      anchor = { block, ms: await pub.readContract({ address: BASE_TIME, abi: timeAbi, functionName: "timestampMs", blockNumber: block }) };
    }
    return anchor.ms - (anchor.block - blockNumber) * BigInt(BLOCK_MS);
  }
}

export async function confirm(hash: Hash): Promise<TransactionReceipt> {
  const r = await pub.waitForTransactionReceipt({ hash, pollingInterval: 100, timeout: 120_000 });
  if (r.status !== "success") throw new Error(`transaction ${hash} reverted`);
  return r;
}

/** eth_getLogs over a long range, in chunks that shrink when the RPC refuses a range. */
export async function logsBetween<T extends Log>(
  fetch: (from: bigint, to: bigint) => Promise<T[]>,
  from: bigint,
  to: bigint,
): Promise<T[]> {
  const out: T[] = [];
  let step = 20_000n;
  let start = from;
  while (start <= to) {
    const end = start + step - 1n > to ? to : start + step - 1n;
    try {
      out.push(...(await fetch(start, end)));
      start = end + 1n;
    } catch (e) {
      if (step <= 500n) throw e;
      step /= 2n;
    }
  }
  return out;
}

export const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

export const fmt = (v: bigint, decimals: number, digits = 2) => (Number(v) / 10 ** decimals).toFixed(digits);
