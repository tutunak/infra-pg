"""Custom ansible-lint rule: get_url tasks must have retries."""
from __future__ import annotations

from typing import TYPE_CHECKING

from ansiblelint.rules import AnsibleLintRule

if TYPE_CHECKING:
    from ansiblelint.file_utils import Lintable
    from ansiblelint.utils import Task

_GET_URL_MODULES = {"get_url", "ansible.builtin.get_url"}


class GetUrlRetriesRule(AnsibleLintRule):
    id = "LOCAL001"
    description = (
        "External download task is missing retries — transient failures will abort the play"
    )
    severity = "MEDIUM"
    tags = ["reliability"]
    version_changed = "26.0.0"

    def matchtask(
        self,
        task: Task,
        file: Lintable | None = None,
    ) -> bool | str:
        """Flag get_url tasks that lack retries or until directives."""
        module = task["action"].get("__ansible_module__", "")
        if module not in _GET_URL_MODULES:
            return False
        if "retries" not in task.raw_task:
            return "get_url task is missing 'retries'"
        if "until" not in task.raw_task:
            return "get_url task has 'retries' but is missing 'until'"
        return False
