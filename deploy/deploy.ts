import {ExecSyncOptions, execSync} from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import chalk from 'chalk';
import minimist from 'minimist';
import chunk from 'chunk';

import {decode} from '../backup/pem';
import {getActor, getAssetsCanisterId} from './utils';


let execOptions = {stdio: ['inherit', 'pipe', 'inherit']} as ExecSyncOptions;

let argv = minimist(process.argv.slice(2));

let network = argv._[0] || 'local';
let dfxNetwork = network === 'local' || network === 'test' ? 'local' : 'ic';
let initArgsFile = network === 'local' || network === 'test' ? 'initArgs.local.did' : 'initArgs.did';

let mode = argv.mode || '';
let modeArg = mode === 'reinstall' ? `--mode=${mode}` : '--mode=auto';

// skip prompt for local reinstall
if (dfxNetwork === 'local' && mode === 'reinstall') {
  modeArg += ' --yes';
}

let withCyclesArg = argv['with-cycles'] ? `--with-cycles=${argv['with-cycles']}` : '';

let nftCanisterName = network == 'production' ? 'production' : 'staging';
let assetsDir = path.resolve(__dirname, '../assets');
let identityName = execSync('dfx identity whoami').toString().trim();
let pemData = execSync(`dfx identity export ${identityName}`, execOptions).toString();
let identity = decode(pemData);
let actor = getActor(network, identity);

if (mode === 'reinstall') {
  console.log(chalk.yellow('REINSTALL MODE'));
}
console.log(chalk.yellow(`Identity: ${identityName}`));
console.log(chalk.yellow(`Controller: ${identity.getPrincipal().toText()}`));
console.log(chalk.yellow(`Canister: ${nftCanisterName}`));
console.log(chalk.yellow(`Network: ${dfxNetwork}`));

let dirContent = fs.readdirSync(assetsDir);
let files = dirContent.filter((item) => {
  return fs.lstatSync(path.resolve(assetsDir, item)).isFile();
});

let filesByName = new Map(files.map((file) => {
  return [path.parse(file).name, file];
}));

// TODO: remove
// populate with fake data for cherries
// let assets = JSON.parse(fs.readFileSync(path.resolve(assetsDir, 'metadata.json')).toString());
// for (let i = 0; i < assets.length; i++) {
//   filesByName.set(String(i), `${i}.svg`);
//   filesByName.set(String(i) + '_thumbnail', `${i}_thumbnail.png`);
// }
// filesByName.set('placeholder', 'placeholder.mp4');

let run = async () => {
  deployNftCanister();
  await uploadAssetsMetadata();
  launch();
  // deployAssetsCanister();
}

let getAssetUrl = (filename) => {
  let assetsCanisterId = getAssetsCanisterId(network);
  let file = filesByName.get(filename);
  if (!file) {
    throw new Error(`File '${filename}' not found`);
  }
  if (!assetsCanisterId) {
    throw new Error('Assets canister id not found');
  }
  if (network === 'local' || network === 'test') {
    return `http://localhost:4943/${file}?canisterId=${assetsCanisterId}`;
  }
  else {
    return `https://${assetsCanisterId}.raw.icp0.io/${file}`;
  }
}

let deployNftCanister = () => {
  console.log(chalk.yellow(`Using init args from ${initArgsFile}`));
  console.log(chalk.green('Building nft canister...'));
  execSync(`dfx build ${nftCanisterName} --network ${dfxNetwork}`, execOptions);
  console.log(chalk.green('Installing nft canister...'));
  execSync(`dfx canister install ${nftCanisterName} --argument-file ${initArgsFile} --network ${dfxNetwork} ${modeArg} ${withCyclesArg}`, execOptions);
}

// let deployAssetsCanister = () => {
//   console.log(chalk.green('Deploying assets canister...'));
//   execSync(`dfx deploy assets --no-wallet --network ${dfxNetwork} ${withCyclesArg}`, execOptions);
// }

let uploadAssetsMetadata = async () => {
  let assets = JSON.parse(fs.readFileSync(path.resolve(assetsDir, 'metadata.json')).toString());

  // placeholder
  if (filesByName.has('placeholder')) {
    console.log(chalk.green('Uploading placeholder...'));
    await actor.addPlaceholder({
      name: 'placeholder',
      payload: {
        ctype: '',
        data: [],
      },
      thumbnail: [],
      metadata: [],
      payloadUrl: [getAssetUrl('placeholder')],
      thumbnailUrl: [],
    });
  }
  else {
    console.log(chalk.yellow('No placeholder.'));
  }

  // assets
  console.log(chalk.green('Uploading assets metadata...'));
  console.log(chalk.green(`Found ${assets.length} assets metadata...`));

  let all = new Set([...assets.keys()]);
  let uploadedCount = 0;

  let chunks = chunk([...assets.entries()], 1000);

  console.log('Chunks:', chunks.length);

  for (let chunk of chunks) {
    let metadataChunk = chunk.map(([index, metadata]) => {
      return {
        name: String(index),
        payload: {
          ctype: '',
          data: [],
        },
        thumbnail: [],
        metadata: [{
          ctype: 'application/json',
          data: [new TextEncoder().encode(JSON.stringify(metadata))],
        }],
        payloadUrl: [getAssetUrl(String(index))],
        thumbnailUrl: [getAssetUrl(String(index) + '_thumbnail')],
      };
    });

    await actor.addAssets(metadataChunk);

    uploadedCount += chunk.length;

    console.log(`Uploaded metadata: ${uploadedCount}`);

    chunk.forEach(([index, _]) => {
      all.delete(index);
    });
  }

  if (all.size > 0) {
    throw new Error(`Failed to upload metadata for ${[...all].join(', ')}`);
  }

  console.log(chalk.green('All assets metadata uploaded'));
};

let launch = () => {
  console.log(chalk.green('Launching...'));
  if (dfxNetwork === 'ic' && nftCanisterName === 'production') {
    console.log('initiating CAP ...');
    execSync(`dfx canister --network ${dfxNetwork} call ${nftCanisterName} initCap`, execOptions);
  }
  else {
    console.log(chalk.yellow('skip CAP init for local network or staging canister'));
  }

  console.log('initiating mint ...');
  execSync(`dfx canister --network ${dfxNetwork} call ${nftCanisterName} initMint`, execOptions);

  console.log('shuffle Tokens For Sale ...');
  execSync(`dfx canister --network ${dfxNetwork} call ${nftCanisterName} shuffleTokensForSale`, execOptions);

  console.log('airdrop tokens ...');
  execSync(`dfx canister --network ${dfxNetwork} call ${nftCanisterName} airdropTokens`, execOptions);

  console.log('enable sale ...');
  execSync(`dfx canister --network ${dfxNetwork} call ${nftCanisterName} enableSale`, execOptions);
}

run();