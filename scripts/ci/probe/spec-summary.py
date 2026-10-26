import collections
import glob
import re
import sys

top = int(sys.argv[1])
paths = sorted(set(glob.glob('/tmp/probe-out/dump-spec/**/*.dump-spec', recursive=True) + glob.glob('**/*.dump-spec', recursive=True)))
print('dump files:', paths)
for path in paths:
    text = open(path, encoding='utf-8', errors='replace').read()
    sections = re.split(r'^={10,} (.+?) ={10,}$', text, flags=re.M)
    print(path, 'bytes', len(text), 'sections', sections[1::2])
    for title, body in zip(sections[1::2], sections[2::2]):
        lines = body.split('\n')
        bindings = []
        for line in lines:
            if line and not line[0].isspace() and not line.startswith('--') and not line.startswith('Result size'):
                bindings.append([re.split(r'[\s=]', line, maxsplit=1)[0], 0, 0, 0])
            if bindings:
                bindings[-1][1] += 1
                bindings[-1][2] += len(re.findall(r'\bjoin(?:rec)? \{', line))
                bindings[-1][3] += len(re.findall(r'\$s[\w$\']*', line))
        print('==', title, 'lines', len(lines), 'top-level bindings', len(bindings))
        for name, count, joins, specs in sorted(bindings, key=lambda b: -b[1])[:top]:
            print('   %8d lines %6d joins %6d $s-names  %s' % (count, joins, specs, name))
        names = collections.Counter(re.sub(r'[\d_]+$', '', m) for m in re.findall(r'\$s[\w$\']*', body))
        print('   $s-names:', names.most_common(top))
