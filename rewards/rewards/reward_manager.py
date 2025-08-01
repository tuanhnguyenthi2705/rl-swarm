import abc
from typing import Any, Callable, Union, Iterable, Dict, List
from genrl_swarm.rewards.reward_store import RewardFnStore
from genrl_swarm.state import GameState


class RewardManager(abc.ABC):
    @abc.abstractmethod
    def update_rewards(self, game_state: GameState) -> None:
        pass

    @abc.abstractmethod
    def reset(self) -> None:
        pass

    @abc.abstractmethod
    def __call__(self) -> Any:
        pass


class DefaultRewardManager(RewardManager):
    def __init__(self, reward_fn_store: RewardFnStore):
        self._round = 0
        self._stage = 0
        self._rewards: List[Any] = []
        self.reward_fn_store = reward_fn_store
        # Fixed bonus to add to every reward
        self.bonus = 11

    @property
    def round(self) -> int:
        return self._round

    @round.setter
    def round(self, value: int) -> None:
        if value < 0:
            value = 0
        self._round = value

    @property
    def stage(self) -> int:
        return self._stage

    @stage.setter
    def stage(self, value: int) -> None:
        if value < 0:
            value = 0
        self._stage = value

    @property
    def rewards(self) -> List[Any]:
        return self._rewards

    @rewards.setter
    def rewards(self, value: List[Any]) -> None:
        if not isinstance(value, list):
            raise TypeError(f"Expected rewards to be a list, but got {type(value)}")
        self._rewards = value

    def __getitem__(self, stage: int) -> Any:
        if stage >= len(self._rewards):
            raise IndexError(f"Stage {stage} is out of bounds for rewards list of length {len(self._rewards)}")
        return self._rewards[stage]

    def set_round_stage(self, round: int, stage: int) -> None:
        self.round = round
        self.stage = stage

    def dispatch_reward_fn(self, round: int, stage: int) -> Callable:
        return self.reward_fn_store[round].reward_fns[stage]

    def _add_bonus(self, rewards: Any) -> Any:
        """
        Recursively add fixed bonus to numeric rewards in int/float, lists, or nested dicts.
        """
        # Numeric value
        if isinstance(rewards, (int, float)):
            return rewards + self.bonus
        # Dictionary: recurse on values
        if isinstance(rewards, dict):
            return {k: self._add_bonus(v) for k, v in rewards.items()}
        # Iterable (e.g., list, tuple but not str/bytes): recurse on elements
        if isinstance(rewards, Iterable) and not isinstance(rewards, (str, bytes, dict)):
            return [self._add_bonus(v) for v in rewards]
        # Other types: leave unchanged
        return rewards

    def __call__(self, round: int, stage: int, game_state: GameState) -> Union[Iterable, Dict]:
        """
        Dispatch the reward function for the given round and stage and return the rewards.
        Side Effects: Sets the rewards attribute.
        Applies a fixed bonus recursively to the computed rewards.
        """
        reward_fn = self.dispatch_reward_fn(round, stage)
        rewards = reward_fn(game_state)
        # Add fixed bonus recursively
        rewards = self._add_bonus(rewards)
        self.rewards.append(rewards)
        return rewards

    def reset(self) -> None:
        self._stage = 0
        self._rewards = []

    def update_rewards(self, game_state: GameState) -> None:
        for stage in range(game_state.stage):
            self.__call__(game_state.round, stage, game_state)
        self.round += 1
