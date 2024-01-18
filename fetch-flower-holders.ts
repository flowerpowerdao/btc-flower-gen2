import {writeFileSync} from 'fs';
import {createActor} from './declarations/main';

let options = {
  agentOptions: {
    host: 'https://icp-api.io',
  }
};

let btcFlower = createActor('pk6rk-6aaaa-aaaae-qaazq-cai', options);
let ethFlower = createActor('dhiaa-ryaaa-aaaae-qabva-cai', options);
let icpFlower = createActor('4ggk4-mqaaa-aaaae-qad6q-cai', options);

(async () => {
  let btcFlowerHolders = (await btcFlower.getRegistry()).map((x) => x[1]);
  let ethFlowerHolders = (await ethFlower.getRegistry()).map((x) => x[1]);
  let icpFlowerHolders = (await icpFlower.getRegistry()).map((x) => x[1]);

  let btcFlowerHoldersUniq = new Set(btcFlowerHolders);
  let trilogyHolders = [];
  for (let address of btcFlowerHoldersUniq) {
    let btcCount = btcFlowerHolders.filter((x) => x === address).length;
    let ethCount = ethFlowerHolders.filter((x) => x === address).length;
    let icpCount = icpFlowerHolders.filter((x) => x === address).length;
    let trilogyCount = Math.min(...[btcCount, ethCount, icpCount]);

    if (trilogyCount) {
      trilogyHolders.push(...Array(trilogyCount).fill(address));
    }
  }

  let icpEthFlowerHolders = [...ethFlowerHolders, ...icpFlowerHolders];

  console.log('trilogy holders', trilogyHolders.length);
  console.log('btc flower holders', btcFlowerHolders.length);
  console.log('icp and eth flower holders', icpEthFlowerHolders.length);

  writeFileSync('holders-trilogy.txt', '"' + trilogyHolders.join('";\n"') + '";');
  writeFileSync('holders-btc-flower.txt', '"' + btcFlowerHolders.join('";\n"') + '";');
  writeFileSync('holders-icp-eth-flower.txt', '"' + icpEthFlowerHolders.join('";\n"') + '";');
})();