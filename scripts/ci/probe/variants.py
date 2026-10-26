import json
import os
import shutil
import subprocess
import sys
import threading
import time

ghc_version = sys.argv[1]
heap_limit = sys.argv[2]
timeout = int(sys.argv[3])
variants = sys.argv[4:]

warnings = '-Weverything -Wno-missing-exported-signatures -Wno-missing-import-lists -Wno-missed-specialisations -Wno-all-missed-specialisations -Wno-unsafe -Wno-safe -Wno-missing-local-signatures -Wno-missing-kind-signatures -Wno-missing-deriving-strategies -Wno-monomorphism-restriction -Wno-prepositive-qualified-module -Wno-unused-packages -Wno-implicit-prelude -Wno-missing-safe-haskell-mode -Wno-missing-export-lists -Wno-partial-fields -Wcompat -Werror=incomplete-record-updates -Werror=incomplete-patterns -Werror=missing-methods -Werror=incomplete-uni-patterns -Werror=tabs -Wredundant-constraints -Wincomplete-record-updates -Wunused-type-patterns -Werror=name-shadowing'.split()

plan = json.load(open('dist-newstyle/cache/plan.json'))
lib = [u for u in plan['install-plan'] if u.get('pkg-name') == 'simplex-chat' and u.get('component-name') == 'lib']
assert len(lib) == 1, lib
depends = lib[0]['depends']
store_db = os.path.join(os.environ['CABAL_DIR'], 'store', 'ghc-' + ghc_version, 'package.db')
inplace_db = os.path.join('dist-newstyle', 'packagedb', 'ghc-' + ghc_version)
package_flags = ['-package-env', '-', '-hide-all-packages', '-no-user-package-db', '-package-db', store_db]
if os.path.isdir(inplace_db):
    package_flags += ['-package-db', inplace_db]
for unit in depends:
    package_flags += ['-package-id', unit]
base_flags = ['ghc', '--make', '-O2', '-XHaskell2010', '-XStrictData', '-dynamic-too'] + warnings + package_flags


def run(name, flags, target):
    out = os.path.join('/tmp/probe-out', name)
    cmd = base_flags + flags + ['-outputdir', out, '-dshow-passes', target, '+RTS', '-s', '-M' + heap_limit, '-RTS']
    print('::group::%s' % name, flush=True)
    print(' '.join(cmd), flush=True)
    start = time.time()
    p = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    timer = threading.Timer(timeout, p.kill)
    timer.start()
    for line in p.stdout:
        print('%7.1f %s' % (time.time() - start, line.rstrip()), flush=True)
    _, status, usage = os.wait4(p.pid, 0)
    timer.cancel()
    elapsed = time.time() - start
    print('::endgroup::', flush=True)
    code = os.waitstatus_to_exitcode(status)
    result = 'RESULT %s exit=%d elapsed_s=%.0f max_rss_mb=%d' % (name, code, elapsed, usage.ru_maxrss // 1024)
    print(result, flush=True)
    return result


def synthetic(construct, n):
    fields = ['f%d' % i for i in range(1, n + 1)]
    lines = [
        '{-# LANGUAGE NamedFieldPuns #-}',
        '{-# LANGUAGE OverloadedStrings #-}',
        '{-# LANGUAGE StrictData #-}',
        '{-# LANGUAGE TemplateHaskell #-}',
        'module Synth where',
        'import Control.Applicative ((<|>))',
        'import Data.Aeson (FromJSON (..), (.:?))',
        'import qualified Data.Aeson as J',
        'import qualified Data.Aeson.TH as JQ',
        'data R = R',
        '  { ' + ',\n    '.join('%s :: Maybe Bool' % f for f in fields),
        '  }',
    ]
    if construct == 'fromjson':
        lines += ['instance FromJSON R where', '  parseJSON (J.Object v) = do']
        lines += ['    %s <- p "%s"' % (f, f) for f in fields]
        lines += ['    pure R {' + ', '.join(fields) + '}', '    where', '      p key = v .:? key <|> pure Nothing', '  parseJSON _ = pure (R' + ' Nothing' * n + ')']
    elif construct == 'tojson':
        lines += ["$(JQ.deriveToJSON J.defaultOptions {J.omitNothingFields = True} ''R)"]
    elif construct == 'combine':
        lines += ['combine :: R -> R -> R', 'combine a b = R {' + ', '.join('%s = p %s' % (f, f) for f in fields) + '}', '  where', '    p :: (R -> Maybe x) -> Maybe x', '    p sel = sel a <|> sel b']
    directory = os.path.join('/tmp/probe-src', '%s-%d' % (construct, n))
    os.makedirs(directory)
    open(os.path.join(directory, 'Synth.hs'), 'w').write('\n'.join(lines) + '\n')
    return directory


results = [run('base', ['-isrc'], 'Simplex.Chat.Types.UITheme')]
for name in variants:
    if name.startswith('synth-'):
        _, construct, n = name.split('-')
        results.append(run(name, ['-i' + synthetic(construct, int(n))], 'Synth'))
        continue
    out = os.path.join('/tmp/probe-out', name)
    shutil.copytree('/tmp/probe-out/base', out)
    source = [] if name == 'master' else ['-iscripts/ci/probe/variants/' + name]
    results.append(run(name, source + ['-isrc'], 'Simplex.Chat.AppSettings'))
print('\n'.join(results))
