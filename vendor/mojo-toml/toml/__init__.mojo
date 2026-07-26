"""Vendored parser-only `mojo-toml` package.

This package exposes TOML lexing and parsing without the unused writer.

Example:
    from toml import parse

    var config = parse('''
        [package]
        name = "mojo-toml"
        version = "0.1.0"
    ''')
"""

from .lexer import Lexer, Token, TokenKind, Position
from .parser import Parser, TomlValue, parse
