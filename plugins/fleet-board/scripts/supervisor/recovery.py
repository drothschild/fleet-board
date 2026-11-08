"""Bounded recovery of durable attempts using independently supplied evidence."""


class Recovery:
    def __init__(self, store, inspector):
        self.store = store
        self.inspector = inspector

    def reconcile(self, now):
        snapshot = self.store.snapshot()
        for attempt in snapshot['attempts']:
            if attempt['state'] not in ('prepared', 'launching', 'running'):
                continue
            try:
                observation = self.inspector.inspect(attempt)
            except (OSError, ValueError):
                observation = {'status': 'unknown'}
            if observation.get('status') == 'unknown':
                revision = self.store.snapshot()['domain']['revision']
                self.store.update_attempt(attempt['id'], {'state': 'quarantined'}, revision)
