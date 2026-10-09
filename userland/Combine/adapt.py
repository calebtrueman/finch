#!/usr/bin/env python3
# SPDX-License-Identifier: MIT OR Apache-2.0
"""Adapt a copy of OpenCombine's sources to be module Combine, with Apple's Combine's names.

  - names qualified with OpenCombine's module become Combine's;
  - the parts OpenCombine leaves out where Apple's Combine exists (#if !canImport(Combine)) are kept;
  - @inlinable goes (OpenCombine's inlinable code doesn't build with library evolution; the ABI
    is the exported symbols);
  - Result.OCombine.Publisher and Optional.OCombine.Publisher, OpenCombine's names for avoiding
    Apple's, become Result.Publisher and Optional.Publisher, as in Apple's Combine.
    adapt.py SRC-DIR
"""
import os
import re
import sys


def block_end(s, open_brace):
    depth = 0
    for i in range(open_brace, len(s)):
        if s[i] == '{':
            depth += 1
        elif s[i] == '}':
            depth -= 1
            if depth == 0:
                return i
    raise ValueError('unbalanced')


def flatten_ocombine(s):
    start = s.index('    public struct OCombine {')
    end = block_end(s, s.index('{', start))
    inner_start = s.index('        public struct Publisher', start)
    inner_end = block_end(s, s.index('{', inner_start))
    publisher = s[inner_start:inner_end + 1]
    # the doc comment before it, too
    doc_start = s.rfind('\n\n', start, inner_start) + 2
    publisher = s[doc_start:inner_start] + publisher
    publisher = '\n'.join(l[4:] if l.startswith('    ') else l for l in publisher.split('\n'))
    # the doc comment before OCombine goes with it
    doc = s.rfind('\n\n', 0, start) + 2
    s = s[:doc] + publisher + s[end + 1:]
    # the ocombine property and the #if block aliasing Publisher
    s = re.sub(r'\n    public var ocombine: OCombine \{\n        return (OCombine\(self\)|\.init\(self\))\n    \}\n', '\n', s)
    s = re.sub(r'\n[^\n]*public typealias Publisher = OCombine\.Publisher\n', '\n', s)
    s = s.replace('.OCombine.Publisher', '.Publisher').replace('.OCombine {', ' {').replace('Result.OCombine', 'Result')
    s = s.replace('Optional.OCombine', 'Optional').replace('OCombine.Publisher', 'Publisher')
    return s


def inlinable(m):
    # internal inlinable code exports its symbols (@usableFromInline); public and private code just loses the attribute
    word = m.group(1)
    if word in ('public', 'open', 'private', 'fileprivate', 'deinit'):
        return ''
    return '@usableFromInline '


# As Apple's Combine: these types' layouts are part of the ABI (apps built against it inline them).
FROZEN = ['public struct AnyPublisher<', 'public struct AnySubscriber<', 'public struct Demand:',
          'public enum Completion<']
FIXED = ['internal class PublisherBoxBase<', 'internal final class PublisherBox<', 'internal class AnySubscriberBase<',
         'internal final class AnySubscriberBox<', 'internal final class ClosureBasedAnySubscriber<']


def freeze(s):
    for d in FROZEN:
        s = s.replace(d, '@frozen ' + d)
    for d in FIXED:
        s = s.replace(d, '@_fixed_layout ' + d)
    return s


def main():
    root = sys.argv[1]
    for dirpath, _, files in os.walk(root):
        for f in files:
            if not f.endswith('.swift'):
                continue
            p = os.path.join(dirpath, f)
            s = open(p).read()
            s = s.replace('OpenCombine.', 'Combine.')
            s = s.replace('#if !canImport(Combine)', "#if true // Finch: Apple's Combine has these")
            s = re.sub(r'@inlinable\s*(?=(?:@\w+(?:\([^)]*\))?\s*)*(\w+))', inlinable, s)
            s = freeze(s)
            if f in ('Result.Publisher.swift', 'Optional.Publisher.swift'):
                s = flatten_ocombine(s)
            s = s.replace('.ocombine.publisher', '.publisher').replace('.OCombine.Publisher', '.Publisher')
            open(p, 'w').write(s)


main()
