import { createHash } from 'node:crypto'
import { readFile, writeFile } from 'node:fs/promises'
import { listMigrationFiles } from '../packages/database-readiness/index.js'
import { readStructureContract } from '../packages/database-readiness/structure-contract.js'

const contractUrl = new URL('../packages/database-readiness/structure-contract.json', import.meta.url)
const contract = JSON.parse(await readFile(contractUrl, 'utf8'))
const files = await listMigrationFiles(process.argv[2])
const hash = bytes => createHash('sha256').update(bytes).digest('hex')

if (contract.format !== 1 || files.length !== contract.migrations.length) {
  throw new Error('Release migration list differs from the structure contract')
}

for (const [index, file] of files.entries()) {
  const expected = contract.migrations[index]
  if (file.version !== expected.version || file.name !== expected.name) {
    throw new Error('Unexpected release migration: ' + file.name)
  }
  const original = await readFile(file.path)
  if (hash(original) === expected.sha256) continue

  // A checkout can alter line endings. Only attest a byte-for-byte contract match.
  const lf = original.toString('utf8').replaceAll('\r\n', '\n')
  const audited = [lf, lf.replaceAll('\n', '\r\n')].find(bytes => hash(bytes) === expected.sha256)
  if (audited === undefined) throw new Error('Release migration content differs: ' + file.name)
  await writeFile(file.path, audited)
}

await readStructureContract(files)
