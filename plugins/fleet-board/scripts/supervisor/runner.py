"""Detached runner interface; production execution remains disabled."""
class Runner:
    def __init__(self, directory):
        self.directory = directory

    def launch(self, prepared_attempt):
        raise NotImplementedError('production worker isolation is unavailable')
