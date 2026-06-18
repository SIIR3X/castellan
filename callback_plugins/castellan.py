# -*- coding: utf-8 -*-
# Castellan - live stdout callback.
#
# Renders the hardening run as a clean, per-role checklist: each measure ticks
# off in real time ([ .. ] -> [ OK ]/[ CHG]/[SKIP]/[FAIL]), with a transient
# "current action" line for the housekeeping tasks in between. ASCII only.
#
# Task names follow the project convention "Role | Label (code)" (see CLAUDE.md);
# the code (e.g. 4.3) marks a measure. Tasks without a code are shown only as the
# transient current action, never as a permanent checklist line (unless failed).
#
# Set CASTELLAN_RAW=1 (handled by ./harden, which switches the stdout callback
# back to yaml) to get Ansible's default verbose output for debugging/diffs.
from __future__ import absolute_import, division, print_function

__metaclass__ = type

import os
import re
import sys

from ansible.plugins.callback import CallbackBase

DOCUMENTATION = '''
    name: castellan
    type: stdout
    short_description: Castellan live per-role hardening checklist
    version_added: "1.0"
    description:
        - Per-role checklist that ticks each measure off in real time.
'''

# Trailing "(code)" where code starts with a digit, e.g. (4.3) or (4.3/4.4/4.10).
_CODE_RE = re.compile(r'\s*\(([0-9][0-9A-Za-z./+ -]*)\)\s*$')

# Helper roles that are included inside category roles; they must not open a new
# section (their tasks are housekeeping with no measure code).
_HELPER_ROLES = frozenset(['backup_config'])

# Friendly phase banners keyed by a substring of the play name.
_PHASES = [
    ('Play 1', 'BOOTSTRAP - create admin + deploy key'),
    ('Play 2', 'VERIFY - reconnect as admin, assert sudo'),
    ('Play 3', 'HARDEN - apply every measure (lockout-safe order)'),
    ('Play 4', 'REPORT - compliance scan + cleanup'),
]

# Minimal ANSI colour (ASCII bytes), only on a TTY.
_COLORS = {
    'OK': '\033[0;32m', 'CHG': '\033[0;33m', 'FAIL': '\033[0;31m',
    'SKIP': '\033[0;90m', 'HEAD': '\033[1;34m', 'RST': '\033[0m',
}


class CallbackModule(CallbackBase):
    CALLBACK_VERSION = 2.0
    CALLBACK_TYPE = 'stdout'
    CALLBACK_NAME = 'castellan'

    def __init__(self):
        super(CallbackModule, self).__init__()
        self.tty = sys.stdout.isatty()
        try:
            self.width = max(40, int(os.environ.get('COLUMNS', '') or 0)
                             or os.get_terminal_size().columns)
        except Exception:
            self.width = 80
        self._dirty = False          # a transient line is currently on screen
        self._play_roles = 0         # role count for the active play
        self._role_idx = 0           # 1-based index of the last printed role
        self._cur_group = None       # current role name (or None for play tasks)
        self._head_role = None       # role whose header is not printed yet
        self._head_printed = False   # did the current role print a header?
        self._pending = None         # (kind, code, label) for the running task
        self._is_handler = False
        self._is_helper_task = False  # current task belongs to a helper role
        self._role = {'done': 0, 'changed': 0, 'skip': 0, 'fail': 0}
        self._total = {'done': 0, 'changed': 0, 'skip': 0, 'fail': 0}

    # --- low-level output ----------------------------------------------------
    def _paint(self, badge):
        if not self.tty:
            return badge
        return _COLORS.get(badge.strip(), '') + badge + _COLORS['RST']

    def _clear(self):
        if self.tty and self._dirty:
            sys.stdout.write('\r' + ' ' * (self.width - 1) + '\r')
            self._dirty = False

    def _transient(self, text):
        # Live "currently doing X" line; only on a TTY, overwritten in place.
        if self.tty:
            self._clear()
            sys.stdout.write(text[:self.width - 1])
            sys.stdout.flush()
            self._dirty = True

    def _line(self, text=''):
        self._clear()
        sys.stdout.write(text + '\n')
        sys.stdout.flush()

    # --- helpers -------------------------------------------------------------
    @staticmethod
    def _split(name):
        # "Role | Label (code)" -> (code or '', label without role prefix/code)
        code = ''
        m = _CODE_RE.search(name)
        if m:
            code = m.group(1)
            name = name[:m.start()]
        if ' | ' in name:
            name = name.split(' | ', 1)[1]
        return code, name.strip()

    def _ensure_header(self):
        # Print the pending role header lazily, only once the role actually has
        # something to show (keeps handler-flush passes from printing empty
        # sections for every role).
        if self._head_printed or self._head_role is None:
            return
        self._role_idx += 1
        total = ('/%d' % self._play_roles) if self._play_roles else ''
        head = '=== [%d%s] %s ' % (self._role_idx, total, self._head_role.upper())
        head = head + '=' * max(0, self.width - len(head) - 1)
        self._line(_COLORS['HEAD'] + head + _COLORS['RST'] if self.tty else head)
        self._head_printed = True

    def _role_summary(self):
        if not self._head_printed:
            return
        r = self._role
        self._line('  ---- done %d  changed %d  skip %d  fail %d'
                   % (r['done'], r['changed'], r['skip'], r['fail']))

    def _finish(self, badge):
        # Finalise the running task line with the given status badge.
        if self._pending is None:
            return
        kind, code, label = self._pending
        self._pending = None
        # Helper-role tasks (backups) are pure housekeeping: hide them unless
        # one actually fails (a failed backup matters).
        if self._is_helper_task and badge != 'FAIL':
            self._clear()
            return
        key = {'OK': 'done', 'CHG': 'changed', 'SKIP': 'skip', 'FAIL': 'fail'}[badge]
        if kind == 'measure':
            self._ensure_header()
            tag = ('H ' if self._is_handler else '') + (code or '-')
            self._line('  [%s] %-9s %s' % (self._paint('%-4s' % badge), tag, label))
            self._role[key] += 1
            self._total[key] += 1
        elif badge in ('CHG', 'FAIL'):
            # A coded measure is the ideal, but many roles apply config in bulk
            # (e.g. "Deploy jail.local"). Surface any non-housekeeping task that
            # actually changed or failed, even without a code; idempotent
            # re-reads (OK/SKIP without a code) stay hidden.
            self._ensure_header()
            tag = 'H ' if self._is_handler else '-'
            self._line('  [%s] %-9s %s' % (self._paint('%-4s' % badge), tag, label))
            self._role[key] += 1
            self._total[key] += 1
        else:
            self._clear()

    # --- callback API --------------------------------------------------------
    def v2_playbook_on_play_start(self, play):
        self._role_summary()
        self._cur_group = None
        self._head_role = None
        self._head_printed = False
        self._role_idx = 0
        try:
            self._play_roles = len(play.get_roles())
        except Exception:
            self._play_roles = 0
        name = play.get_name() or ''
        banner = name
        for key, label in _PHASES:
            if key in name:
                banner = label
                break
        head = '==== ' + banner + ' '
        head = head + '=' * max(0, self.width - len(head) - 1)
        self._line('')
        self._line(_COLORS['HEAD'] + head + _COLORS['RST'] if self.tty else head)

    @staticmethod
    def _role_of(task):
        try:
            if task._role:
                return task._role.get_name()
        except Exception:
            pass
        return None

    def _maybe_section(self, role):
        # Helper roles (backup_config) run inside category roles - keep the
        # current section rather than opening a noisy new one.
        if role in _HELPER_ROLES:
            return
        if role == self._cur_group:
            return
        self._role_summary()
        self._cur_group = role
        self._role = {'done': 0, 'changed': 0, 'skip': 0, 'fail': 0}
        # Defer the header until the role actually shows a measure (_ensure_header).
        self._head_role = role
        self._head_printed = False

    def _task_start(self, task):
        role = self._role_of(task)
        self._is_helper_task = role in _HELPER_ROLES
        self._maybe_section(role)
        code, label = self._split(task.get_name() or '')
        if code:
            self._pending = ('measure', code, label)
            self._transient('  [ .. ] %-9s %s  << en cours'
                            % (('H ' if self._is_handler else '') + code, label))
        else:
            self._pending = ('action', '', label)
            self._transient('  ...... %s' % label)

    def v2_playbook_on_task_start(self, task, is_conditional):
        self._is_handler = False
        self._task_start(task)

    def v2_playbook_on_handler_task_start(self, task):
        self._is_handler = True
        self._task_start(task)

    def v2_runner_on_ok(self, result):
        changed = bool(result._result.get('changed'))
        self._finish('CHG' if changed else 'OK')

    def v2_runner_on_failed(self, result, ignore_errors=False):
        if ignore_errors:
            self._finish('OK')
        else:
            self._finish('FAIL')

    def v2_runner_on_skipped(self, result):
        self._finish('SKIP')

    def v2_runner_on_unreachable(self, result):
        if self._pending is None:
            self._pending = ('action', '', 'host unreachable')
        kind, code, label = self._pending
        self._pending = ('measure', code or '-', label)
        self._finish('FAIL')
        msg = result._result.get('msg', 'unreachable')
        self._line('         %s' % msg)

    def v2_playbook_on_stats(self, stats):
        self._role_summary()
        self._line('')
        t = self._total
        bar = ('TOTAL  measures applied %d  changed %d  skipped %d  failed %d'
               % (t['done'] + t['changed'], t['changed'], t['skip'], t['fail']))
        self._line(_COLORS['HEAD'] + '=' * (self.width - 1) + _COLORS['RST']
                   if self.tty else '=' * (self.width - 1))
        self._line(bar)
        # Per-host unreachable/failed recap from Ansible's own counters.
        for host in sorted(stats.processed.keys()):
            s = stats.summarize(host)
            flag = 'FAIL' if (s['failures'] or s['unreachable']) else 'OK'
            self._line('  %s  %-22s ok=%d changed=%d unreachable=%d failed=%d'
                       % (self._paint('%-4s' % flag), host, s['ok'],
                          s['changed'], s['unreachable'], s['failures']))
        self._line('')
