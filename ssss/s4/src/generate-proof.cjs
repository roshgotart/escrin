const { StandardMerkleTree } = require('./merkle-tree.cjs');

let chunks = [];
process.stdin.on('readable', () => {
  let chunk;
  while ((chunk = process.stdin.read()) !== null) chunks.push(chunk);
});

process.stdin.on('end', () => {
  let { signers, signatories } = JSON.parse(Buffer.concat(chunks));
  const tree = StandardMerkleTree.of([signers], ['address']);
  process.stdout.write(
    JSON.stringify(
      signatories.length > 0
        ? tree.getMultiProof([signatories])
        : { proof: [tree.root], proofFlags: [], leaves: [] },
    ),
  );
});
