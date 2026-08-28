import uuid

import pytest
from docker.errors import DockerException

from app.models.agent import Agent
from app.services.agent_manager import AgentManager


@pytest.mark.asyncio
async def test_container_start_failure_keeps_native_agent_idle(tmp_path, monkeypatch) -> None:
    agent = Agent(
        id=uuid.uuid4(),
        tenant_id=uuid.uuid4(),
        creator_id=uuid.uuid4(),
        name="No Container",
        status="creating",
        agent_type="native",
    )

    class FakeContainers:
        def run(self, *args, **kwargs) -> None:
            raise DockerException("image not found")

    class FakeDocker:
        containers = FakeContainers()

    manager = AgentManager()
    manager.docker_client = FakeDocker()

    async def fake_materialize(agent_id) -> object:
        return tmp_path

    async def fake_resolve_model(db, agent) -> None:
        return None

    monkeypatch.setattr(manager, "_materialize_agent_dir", fake_materialize)
    monkeypatch.setattr(
        "app.services.agent_manager.resolve_active_agent_model",
        fake_resolve_model,
    )

    result = await manager.start_container(db=None, agent=agent)

    assert result is None
    assert agent.status == "idle"
    assert agent.container_id is None
    assert agent.container_port is None
    assert agent.last_active_at is not None
