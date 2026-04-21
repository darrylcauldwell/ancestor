"""Agent configuration."""

# Model — DeepSeek-R1 for strategic reasoning (slower but correct)
MODEL_NAME = "mlx-community/DeepSeek-R1-Distill-Qwen-14B-4bit"
MAX_TOKENS = 2048

# Research limits
MAX_DEPTH = 3          # How many generations to branch into
MAX_PERSONS = 50       # Hard stop on total persons researched
MAX_RETRIES = 2        # Retry LLM call if JSON parse fails

# Search parameters
CIVIL_REGISTRATION_START = 1837  # FreeBMD only covers 1837+
WW1_START = 1880                 # Born after this might serve in WW1
WW1_END = 1900                   # Born before this might serve in WW1
CENSUS_YEARS = [1841, 1851, 1861, 1871, 1881, 1891, 1901, 1911]
from project_config import config as _cfg
DEFAULT_COUNTY = _cfg.region.chapman_code or "DBY"

# Match scoring thresholds
MATCH_ACCEPT = 0.8     # Score above this = confirmed match
MATCH_UNCERTAIN = 0.4  # Score between this and ACCEPT = ask LLM
MATCH_REJECT = 0.4     # Score below this = rejected
