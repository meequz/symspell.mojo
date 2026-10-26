"""SymSpell spelling correction in pure Mojo.

A port of symspellpy (https://github.com/mammothb/symspellpy) and the original
C# SymSpell by Wolf Garbe (https://github.com/wolfgarbe/SymSpell).
"""

from .builder import SymSpellBuilder
from .config import DistanceAlgorithm, SymSpellConfig
from .index import SymSpell
from .scratch import LookupScratch
from .suggestion import Suggestion
from .verbosity import Verbosity
