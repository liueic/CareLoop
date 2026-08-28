from pydantic_settings import BaseSettings


class Settings(BaseSettings):
    app_name: str = "health-rule-engine"
    app_version: str = "0.1.0"
    debug: bool = False

    database_url: str = "sqlite+aiosqlite:///./health_rule_engine.db"
    redis_url: str = "redis://localhost:6379/0"

    rules_dir: str = "rules"
    active_ruleset_version: str = "2024.1"

    model_config = {"env_prefix": "HRE_", "env_file": ".env"}


settings = Settings()
