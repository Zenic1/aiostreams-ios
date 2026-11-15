#!/usr/bin/env python3
"""Builds the Apple TV app's string tables, TV/Localization/<language>.lproj.

The app's strings are its English text, each passed through `L("...")` (TV/Sources/Language.swift).
A string's translation comes from upstream's catalogue where the web app says the same thing
(packages/web/src/locales/<language>.po), else from scripts/localization/tv-strings.json. A count
with `%ld` takes its plural forms from upstream's ICU plural or from tv-strings.json's plurals.

    scripts/localization/build.py <AIOStreams checkout at web/AIOSTREAMS_REF>

Fails, listing what's missing, when a string has no translation in a language or a translation's
placeholders don't match its string's. To add a string: use it through L in the app, run this, and
add whatever it lists to tv-strings.json.
"""
import json
import os
import re
import sys
from xml.sax.saxutils import escape

ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..'))
SOURCES = os.path.join(ROOT, 'TV', 'Sources')
OUT = os.path.join(ROOT, 'TV', 'Localization')
OURS = json.load(open(os.path.join(ROOT, 'scripts', 'localization', 'tv-strings.json'), encoding='utf-8'))

# The web app's listed catalogues (at least half translated), by its locale id, with the folder here.
LANGUAGES = {'ar': 'ar', 'de': 'de', 'el': 'el', 'es': 'es', 'fr': 'fr', 'id': 'id', 'it': 'it', 'ms': 'ms', 'pl': 'pl',
             'pt-BR': 'pt-BR', 'pt': 'pt-PT', 'ro': 'ro', 'tr': 'tr', 'zh-Hans': 'zh-Hans'}

# The counts, in English; their translations come from these upstream messages where it has them.
ENGLISH_PLURALS = {
    '%ld seconds': {'one': '%ld second', 'other': '%ld seconds'},
    '%ld titles': {'one': '%ld title', 'other': '%ld titles'},
    '%ld versions': {'one': '%ld version', 'other': '%ld versions'},
    'After %ld episodes': {'one': 'After %ld episode', 'other': 'After %ld episodes'},
    'in %ld days': {'one': 'in %ld day', 'other': 'in %ld days'},
    'in %ld weeks': {'one': 'in %ld week', 'other': 'in %ld weeks'},
    '%ld seconds before the end': {'one': '%ld second before the end', 'other': '%ld seconds before the end'},
}
UPSTREAM_PLURALS = {
    '%ld seconds': '{count, plural, one {# second} other {# seconds}}',
    '%ld titles': '{count, plural, one {# title} other {# titles}}',
    '%ld versions': '{found, plural, one {# version} other {# versions}}',
    'After %ld episodes': '{n, plural, one {After # episode} other {After # episodes}}',
}
CATEGORIES = ('zero', 'one', 'two', 'few', 'many', 'other')
SPEC = re.compile(r'%(?:\d\$)?(@|ld)')


def specs(text):
    return [m.group(1) for m in SPEC.finditer(text)]


def keys_in_sources():
    found = []
    for name in sorted(os.listdir(SOURCES)):
        if name.endswith('.swift'):
            for key in re.findall(r'\bL\("((?:[^"\\]|\\.)*)"', open(os.path.join(SOURCES, name), encoding='utf-8').read()):
                if key not in found:
                    found.append(key)
    return found


def parse_po(path):
    """A gettext catalogue's entries: msgctxt, msgid, msgstr and flags."""
    entries, entry, field = [], {'flags': []}, None
    for line in open(path, encoding='utf-8'):
        line = line.rstrip('\n')
        if not line.strip():
            if entry.get('msgid') is not None:
                entries.append(entry)
            entry, field = {'flags': []}, None
            continue
        if line.startswith('#,'):
            entry['flags'] += [f.strip() for f in line[2:].split(',')]
            continue
        if line.startswith('#'):
            continue
        m = re.match(r'(msgctxt|msgid|msgstr)\s+"(.*)"$', line)
        if m:
            field = m.group(1)
            entry[field] = m.group(2)
            continue
        m = re.match(r'"(.*)"$', line)
        if m and field:
            entry[field] += m.group(1)
    if entry.get('msgid') is not None:
        entries.append(entry)
    for e in entries:
        for f in ('msgid', 'msgstr'):
            if f in e:
                e[f] = e[f].encode('utf-8').decode('unicode_escape').encode('latin-1').decode('utf-8') if '\\' in e[f] else e[f]
    return entries


def placeholders_as(text):
    return re.sub(r'\{[^{}]*\}', '{}', text)


def icu_forms(text):
    """`{n, plural, one {...} other {...}}` as its forms, with # as %ld."""
    m = re.match(r'\s*\{\s*\w+\s*,\s*plural\s*,(.*)\}\s*$', text, re.S)
    if not m:
        raise ValueError('not a plural: ' + text)
    body, forms, i = m.group(1), {}, 0
    while True:
        mm = re.compile(r'\s*(=?\w+)\s*\{').match(body, i)
        if not mm:
            break
        j, depth = mm.end(), 1
        while depth:
            depth += {'{': 1, '}': -1}.get(body[j], 0)
            j += 1
        forms[mm.group(1)] = body[mm.end():j - 1].replace('#', '%ld')
        i = j
    if '=1' in forms and 'one' not in forms:
        forms['one'] = forms['=1']
    return {k: v for k, v in forms.items() if k in CATEGORIES}


def convert(msgid, key, translation):
    """Upstream's `{name}` placeholders as the key's, in order, positional where there are several."""
    names, kinds = re.findall(r'\{([^{}]*)\}', msgid), specs(key)
    if len(names) != len(kinds):
        raise ValueError(f'{key!r} has other placeholders than {msgid!r}')
    for n, (name, kind) in enumerate(zip(names, kinds), 1):
        translation = translation.replace('{' + name + '}', f'%{n}${kind}' if len(kinds) > 1 else f'%{kind}')
    return translation


def strings_escape(text):
    return text.replace('\\', '\\\\').replace('"', '\\"').replace('\n', '\\n')


def write(folder, strings, plurals):
    where = os.path.join(OUT, folder + '.lproj')
    os.makedirs(where, exist_ok=True)
    with open(os.path.join(where, 'Localizable.strings'), 'w', encoding='utf-8') as f:
        f.write('/* Generated by scripts/localization/build.py: the app\'s strings, by their English text. */\n\n')
        for key in sorted(strings):
            f.write(f'"{strings_escape(key)}" = "{strings_escape(strings[key])}";\n')
    with open(os.path.join(where, 'Localizable.stringsdict'), 'w', encoding='utf-8') as f:
        f.write('<?xml version="1.0" encoding="UTF-8"?>\n'
                '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n'
                '<plist version="1.0">\n<dict>\n')
        for key in sorted(plurals):
            f.write(f'\t<key>{escape(key)}</key>\n\t<dict>\n'
                    '\t\t<key>NSStringLocalizedFormatKey</key>\n\t\t<string>%#@count@</string>\n'
                    '\t\t<key>count</key>\n\t\t<dict>\n'
                    '\t\t\t<key>NSStringFormatSpecTypeKey</key>\n\t\t\t<string>NSStringPluralRuleType</string>\n'
                    '\t\t\t<key>NSStringFormatValueTypeKey</key>\n\t\t\t<string>ld</string>\n')
            for category in CATEGORIES:
                if category in plurals[key]:
                    f.write(f'\t\t\t<key>{category}</key>\n\t\t\t<string>{escape(plurals[key][category])}</string>\n')
            f.write('\t\t</dict>\n\t</dict>\n')
        f.write('</dict>\n</plist>\n')


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    locales = os.path.join(sys.argv[1], 'packages', 'web', 'src', 'locales')
    keys = keys_in_sources()
    template = {}
    for e in parse_po(os.path.join(locales, 'messages.pot')):
        if e['msgid']:
            template.setdefault(placeholders_as(e['msgid']), e['msgid'])
    problems = []
    write('en', {}, {k: v for k, v in ENGLISH_PLURALS.items() if k in keys})
    for language, folder in LANGUAGES.items():
        upstream = {e['msgid']: e['msgstr'] for e in parse_po(os.path.join(locales, language + '.po'))
                    if e.get('msgstr') and 'fuzzy' not in e['flags']}
        strings, plurals = {}, {}
        for key in keys:
            if key in ENGLISH_PLURALS:
                if key in UPSTREAM_PLURALS and upstream.get(UPSTREAM_PLURALS[key]):
                    forms = icu_forms(upstream[UPSTREAM_PLURALS[key]])
                else:
                    forms = OURS['plurals'].get(key, {}).get(language)
                # A form may leave the number out ("one second"), but `other` says it.
                if not forms or specs(forms.get('other', '')) != ['ld'] or any(specs(v) not in ([], ['ld']) for v in forms.values()):
                    problems.append(f'{language}: plural {key!r}: {forms!r}')
                    continue
                plurals[key] = forms
                continue
            if '%ld' in key:
                problems.append(f'{key!r} counts, so it needs plural forms in ENGLISH_PLURALS')
                continue
            msgid = template.get(re.sub(r'%(@|ld)', '{}', key))
            if msgid and upstream.get(msgid):
                value = convert(msgid, key, upstream[msgid])
            else:
                value = OURS['strings'].get(key, {}).get(language)
            if value is None:
                problems.append(f'{language}: no translation for {key!r}')
                continue
            positions = sorted(int(n) for n in re.findall(r'%(\d)\$', value))
            if sorted(specs(value)) != sorted(specs(key)) or (positions and positions != list(range(1, len(specs(key)) + 1))):
                problems.append(f'{language}: {key!r} -> {value!r} has other placeholders')
            if specs(key) and re.search(r'%(?!(\d\$)?(@|ld))', value):
                problems.append(f'{language}: a lone % in {value!r}')
            strings[key] = value
        write(folder, strings, plurals)
        print(f'{language}: {len(strings)} strings, {len(plurals)} counts')
    if problems:
        sys.exit('\n'.join(sorted(set(problems))))


main()
