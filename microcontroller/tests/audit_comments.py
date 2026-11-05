#!/usr/bin/env python3
"""audit active comments and bind the reviewed source bytes."""
import argparse
import ast
import hashlib
import io
import json
from pathlib import Path
import re
import tokenize

# historical evidence and generated build outputs are not active implementation files.
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--output', type=Path, required=True)
args = parser.parse_args()
root = Path(__file__).resolve().parents[2]
evidence = root / 'microcontroller/verification/evidence/verification-2026-11-04'
files = sorted(p for p in (root / 'microcontroller').rglob('*') if p.is_file() and
               (p.suffix in {'.sv', '.svh', '.v', '.py', '.lpf', '.c', '.cpp', '.h', '.S', '.ld', '.yaml', '.yml', '.tcl', '.sby', '.sh'} or p.name in {'Makefile', 'drg5-act4-gcc'}) and
               not any(part in {'evidence', 'revisions', '__pycache__'} for part in p.relative_to(root).parts))
files += sorted(evidence.glob('*/*.py'))
# executed recovery launchers remain active code even inside retained campaign directories.
files += sorted(evidence.glob('campaigns/*/recovery.py'))
comments = []
missing_sv = []
missing_python = []
missing_cpp = []
cpp_scopes = 0
sv_begin = sv_declarations = python_scopes = 0
# parse strings separately so comment-like literals cannot count as explanations.
for path in files:
    content = path.read_text()
    relative = str(path.relative_to(root))
    # SV declarations and nonempty begin scopes require preceding comment context.
    if path.suffix in {'.sv', '.svh', '.v'}:
        pieces = list(re.finditer(r'/\*[\s\S]*?\*/|//[^\n]*|"(?:\\.|[^"\\])*"|[A-Za-z_$][\w$]*|\S', content))
        tokens = [m for m in pieces if not m.group().startswith(('/*', '//'))]
        comm = [m for m in pieces if m.group().startswith(('/*', '//'))]
        comments += [(relative, content.count('\n', 0, m.start()) + 1, m.group()) for m in comm]
        # include declaration scopes, conditionals, loops and named begin scopes.
        for index, token in enumerate(tokens):
            word = token.group()
            # a declaration's explanation immediately precedes its keyword.
            if word in {'module', 'package', 'function', 'task', 'always', 'always_ff', 'always_comb', 'always_latch', 'initial'}:
                sv_declarations += 1
                preceding = content[:token.start()].rstrip()
                # missing declaration context is an audit failure.
                if not preceding.endswith('*/'):
                    missing_sv.append([relative, content.count('\n', 0, token.start()) + 1, word])
            # an empty begin scope contains no behavior requiring an explanation.
            if word == 'begin':
                following = index + 1
                # named scopes insert a label before their body.
                if tokens[following].group() == ':':
                    following += 2
                # skip an empty scope after accounting for its optional label.
                if tokens[following].group() == 'end':
                    continue
                sv_begin += 1
                depth = boundary = 0
                # ignore header delimiters inside loop or condition parentheses.
                for previous in reversed(tokens[:index]):
                    value = previous.group()
                    # walk balanced headers backward to find the preceding statement boundary.
                    if value in {')', ']'}:
                        depth += 1
                    # opening delimiters close the reverse walk's nesting level.
                    elif value in {'(', '['}:
                        depth -= 1
                    # the comment must follow the preceding completed statement or scope.
                    elif depth == 0 and value in {';', 'begin', 'endcase', 'endfunction', 'endtask'}:
                        boundary = previous.end()
                        break
                before = [m for m in comm if boundary <= m.start() < token.start()]
                # missing begin context is reported with an exact source line.
                if not before:
                    missing_sv.append([relative, content.count('\n', 0, token.start()) + 1, 'begin'])
    # Python docstrings explain functions; hash comments explain control scopes.
    elif path.suffix == '.py':
        tree = ast.parse(content)
        lines = content.splitlines()
        comm = list(tokenize.generate_tokens(io.StringIO(content).readline))
        comments += [(relative, t.start[0], t.string) for t in comm if t.type == tokenize.COMMENT]
        # count module, class and function docstrings alongside ordinary comments.
        for node in ast.walk(tree):
            # only these AST nodes support a leading docstring.
            if isinstance(node, (ast.Module, ast.ClassDef, ast.FunctionDef, ast.AsyncFunctionDef)):
                doc = ast.get_docstring(node)
                # include each explanatory docstring once.
                if doc:
                    comments.append((relative, node.body[0].lineno, doc))
            # inspect explicit block headers, including exception handlers.
            if isinstance(node, (ast.ClassDef, ast.FunctionDef, ast.AsyncFunctionDef, ast.If,
                                 ast.For, ast.AsyncFor, ast.While, ast.With, ast.AsyncWith,
                                 ast.Try, ast.ExceptHandler)):
                python_scopes += 1
                previous = node.lineno - 2
                # blank spacing does not separate an explanation from its scope.
                while previous >= 0 and not lines[previous].strip():
                    previous -= 1
                doc = ast.get_docstring(node) if isinstance(node, (ast.ClassDef, ast.FunctionDef, ast.AsyncFunctionDef)) else None
                # preserve the diagnostic header for manual review.
                if not doc and (previous < 0 or not lines[previous].lstrip().startswith('#')):
                    missing_python.append([relative, node.lineno, type(node).__name__])
        # else and finally suites lack independent AST line numbers.
        for index, line in enumerate(lines):
            # check every continuation arm directly in the source.
            if re.match(r'\s*(else|finally|except|elif)\b.*:', line):
                previous = index - 1
                # a nearby comment may be separated by blank lines only.
                while previous >= 0 and not lines[previous].strip():
                    previous -= 1
                # repeated except findings are removed below.
                if previous < 0 or not lines[previous].lstrip().startswith('#'):
                    missing_python.append([relative, index + 1, 'continuation'])
    # C++ scope checks ignore literals and braced initializers.
    elif path.suffix in {'.c', '.cpp', '.h', '.S', '.ld'}:
        pieces = list(re.finditer(r"/\*[\s\S]*?\*/|//[^\n]*|\"(?:\\.|[^\"\\])*\"|'(?:\\.|[^'\\])*'|[A-Za-z_$][\w$]*|\S", content))
        tokens = [m for m in pieces if not m.group().startswith(('/*', '//'))]
        comm = [m for m in pieces if m.group().startswith(('/*', '//'))]
        comments += [(relative, content.count('\n', 0, m.start()) + 1, m.group()) for m in comm]
        # inspect declarations and executable scopes without treating aggregate data as code.
        for index, token in enumerate(tokens):
            # empty scopes and initializer braces do not require behavioral context.
            if token.group() != '{' or index == 0 or tokens[index + 1].group() == '}':
                continue
            previous = tokens[index - 1].group()
            header_start = content.rfind('\n', 0, token.start()) + 1
            header = content[header_start:token.start()]
            # named declarations, function bodies and explicit control suites are code blocks.
            if previous not in {')', 'else', 'try', 'do'} and not re.search(r'\b(class|struct|namespace|union|enum)\b', header):
                continue
            cpp_scopes += 1
            depth = boundary = 0
            # balanced headers may contain initializer braces or loop semicolons.
            for earlier in reversed(tokens[:index]):
                value = earlier.group()
                # close delimiters enter reverse nesting.
                if value in {')', ']'}:
                    depth += 1
                # opening delimiters leave reverse nesting.
                elif value in {'(', '['}:
                    depth -= 1
                # completed statements and enclosing scope starts delimit local context.
                elif depth == 0 and value in {';', '{'}:
                    boundary = earlier.end()
                    break
            # scope comments may precede the header or appear inside it.
            if not any(boundary <= m.start() < token.start() for m in comm):
                missing_cpp.append([relative, content.count('\n', 0, token.start()) + 1, 'scope'])
    # assembly and linker files retain block comments without parsing preprocessor directives.
    elif path.suffix in {'.S', '.ld'}:
        comments += [(relative, content.count('\n', 0, m.start()) + 1, m.group())
                     for m in re.finditer(r'/\*[\s\S]*?\*/', content)]
    # Makefile and LPF comments use hash-prefixed explanatory lines.
    else:
        comments += [(relative, n, line) for n, line in enumerate(content.splitlines(), 1)
                     if line.lstrip().startswith('#')]

# capitalization exceptions are names, standard units or plural acronyms.
allowed = {'LEDs', 'CSRs', 'Zicsr', 'Zifencei', 'Zicntr', 'Zihpm', 'SystemVerilog', 'Trellis', 'MHz', 'HINTs', 'Verilator', 'GPRs', 'IDs', 'UIDs', 'Python', 'Makefile', 'OpenOCD', 'GDB', 'Boolean', 'Debug', 'Module', 'Tcl', 'Zca', 'Zmmul', 'Sail', 'SymbiYosys', 'Yosys', 'xPack', 'ELFs', 'APIs', 'PCs', 'URLs', 'KiB', 'SoC', 'trap.S'}
unexpected = []
# uppercase acronyms remain valid without a finite acronym allowlist.
for name, line, comment in comments:
    # extract prose words without confusing punctuation or numbers with capitalization.
    for word in re.findall(r'\b[A-Za-z_][A-Za-z_0-9]*(?:\.[A-Za-z_0-9]+)*\b', comment):
        # mixed-case prose needs an explicit reviewed exception.
        if any(c.isupper() for c in word) and not word.isupper() and word not in allowed:
            unexpected.append([name, line, word])
result = {
    'scope': 'all active microcontroller source/build files and current verification evidence runners; immutable historical evidence and generated outputs excluded',
    'files': len(files), 'comment_blocks': len(comments),
    'nonempty_sv_begin_blocks': sv_begin, 'sv_declarations': sv_declarations,
    'python_scopes': python_scopes, 'cpp_scopes': cpp_scopes,
    'methods': {
        'case': 'literal-aware SV extraction; Python tokenize comments and AST docstrings; uppercase acronyms and enumerated mixed-case names allowed',
        'sv': 'preceding block comments for module/package/function/task/always/initial; token-aware nonempty begin context including loop headers',
        'python': 'function/class docstring or preceding comment; comments before if/for/while/with/try/except and continuation suites',
        'cpp': 'literal-aware comments and nonempty executable/declaration braces; initializers excluded',
        'manual': 'new verification runners, formal fixtures, platform macros, execution capture and replay blocks reviewed for explanatory meaning',
        'limits': 'lexical checks do not prove prose truth or concision; single-statement SV arms and Makefile recipes require manual semantic judgment',
    },
    'permitted_mixed_case': sorted(allowed),
    'unexpected_mixed_case': unexpected,
    'missing_sv_context': missing_sv,
    'missing_python_context': missing_python,
    'missing_cpp_context': missing_cpp,
    'source_sha256': {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest() for p in files},
}
args.output.parent.mkdir(parents=True, exist_ok=True)
args.output.write_text(json.dumps(result, indent=2) + '\n')
# no unresolved lexical finding may be summarized as a passing audit.
assert not unexpected and not missing_sv and not missing_python and not missing_cpp, 'comment audit findings remain'
print(f'COMMENT_AUDIT_PASS files={len(files)} comments={len(comments)} SV_begin={sv_begin} Python_scopes={python_scopes}')
