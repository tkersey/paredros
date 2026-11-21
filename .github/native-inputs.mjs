// These keys select compiler caches. Each stage still runs and authenticates its output.
import { createHash } from 'node:crypto';
import { execFileSync } from 'node:child_process';
import { lstatSync, readFileSync } from 'node:fs';

const target = 'x86_64-linux-musl';
const recipes = {
  acquisition: ['build', 'setup', '-Doptimize=safe', '-j2', '--verbose', '--summary', 'all'],
  preparation: ['build', 'prepare-native', '-Dnative=true', '-Dtarget=' + target,
    '-Doptimize=safe', '-j2', '--verbose', '--summary', 'all'],
};
const operation = process.argv[2];
if (Object.hasOwn(recipes, operation)) {
  execFileSync('zig', recipes[operation], {stdio: 'inherit'});
} else if (operation === 'keys') {
  const digest = bytes => createHash('sha256').update(bytes).digest('hex');
  const identity = file => {
    const stat = lstatSync(file);
    if (!stat.isFile()) throw new Error('Expected a regular build input: ' + file);
    return [file, stat.mode & 0o777, digest(readFileSync(file))];
  };
  const distribution = process.env.COMPILER_SHA256;
  if (!/^[0-9a-f]{64}$/.test(distribution ?? '')) throw new Error('Missing Zig distribution digest');
  const version = execFileSync('zig', ['version'], {encoding: 'utf8'}).trim();
  const clang = execFileSync('zig', ['cc', '-target', target, '--version'], {encoding: 'utf8'}).split('\n')[0];
  if (!/\bclang version\b/i.test(clang)) throw new Error('Expected the bundled Clang');
  // The package hash in build.zig.zon binds Protean's acquisition code and both native locks.
  const acquisition = digest(JSON.stringify({
    distribution, version, clang, host: [process.platform, process.arch], target,
    zigDebugCmd: process.env.ZIG_DEBUG_CMD, recipe: recipes.acquisition,
    files: ['build.zig', 'build.zig.zon'].map(identity),
  }));
  const files = execFileSync('git', ['ls-files', '-z', '--cached', '--others', '--exclude-standard',
    '--', 'main.zig', 'environment.zig', 'app/', 'native/', '*.h', '*.c', '*.inc'],
    {encoding: 'utf8'}).split('\0').filter(Boolean).sort();
  const preparation = digest(JSON.stringify({
    acquisition, recipe: recipes.preparation, files: files.map(identity),
  }));
  console.log('acquisition=paredros-acquire-v3-' + acquisition);
  console.log('preparation=paredros-prepare-v3-' + preparation);
} else {
  throw new Error('Expected keys, acquisition or preparation');
}
