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

  let trilogyHoldersUniq = Array.from(new Set(btcFlowerHolders.filter((x) => ethFlowerHolders.includes(x) && icpFlowerHolders.includes(x))));
  let btcFlowerHoldersUniq = Array.from(new Set(btcFlowerHolders));
  let icpEthFlowerHoldersUniq = Array.from(new Set([...ethFlowerHolders, ...icpFlowerHolders]))

  console.log('trilogy holders', trilogyHoldersUniq.length);
  console.log('btc flower holders', btcFlowerHoldersUniq.length);
  console.log('icp or eth flower holders', icpEthFlowerHoldersUniq.length);

  writeFileSync('holders-trilogy.txt', '"' + trilogyHoldersUniq.join('";\n"') + '";');
  writeFileSync('holders-btc-flower.txt', '"' + btcFlowerHoldersUniq.join('";\n"') + '";');
  writeFileSync('holders-icp-eth-flower.txt', '"' + icpEthFlowerHoldersUniq.join('";\n"') + '";');
})();