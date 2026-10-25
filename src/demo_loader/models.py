from __future__ import annotations

import re
from datetime import datetime
from typing import Annotated, Literal, Self
from uuid import UUID

from pydantic import BaseModel, ConfigDict, EmailStr, Field, model_validator

Key = Annotated[str, Field(pattern=r"^[a-z][a-z0-9_-]{0,39}$")]
Text = Annotated[str, Field(min_length=1, max_length=10000)]


class StrictModel(BaseModel):
    model_config = ConfigDict(extra="forbid")


class DemoUser(StrictModel):
    key: Key
    displayName: Annotated[str, Field(min_length=1, max_length=100)]
    userPrincipalName: EmailStr


class Users(StrictModel):
    users: Annotated[list[DemoUser], Field(min_length=5, max_length=5)]

    @model_validator(mode="after")
    def unique(self) -> Self:
        if len({u.key for u in self.users}) != 5:
            raise ValueError("Five distinct user keys are required")
        if len({u.userPrincipalName.lower() for u in self.users}) != 5:
            raise ValueError("Five distinct UPNs are required")
        return self


class Channel(StrictModel):
    teamId: UUID
    channelId: Annotated[str, Field(pattern=r"^19:[A-Za-z0-9_.@:-]{1,250}$")]


class Resources(StrictModel):
    channels: dict[Key, Channel] = Field(default_factory=dict)


class ActivityBase(StrictModel):
    id: Key
    user: Key
    dependsOn: Annotated[list[Key], Field(max_length=200)] = Field(default_factory=list)
    delaySeconds: Annotated[int, Field(ge=0, le=3600)] = 0
    body: Text


class Email(ActivityBase):
    type: Literal["email"]
    to: Annotated[list[str], Field(min_length=1, max_length=10)]
    cc: Annotated[list[str], Field(max_length=10)] = Field(default_factory=list)
    subject: Annotated[str, Field(min_length=1, max_length=250)]
    bodyType: Literal["text", "html"] = "text"
    importance: Literal["low", "normal", "high"] = "normal"


class TeamsMessage(ActivityBase):
    type: Literal["teamsMessage"]
    channel: Key


class TeamsReply(ActivityBase):
    type: Literal["teamsReply"]
    channel: Key
    parent: Key


Activity = Annotated[Email | TeamsMessage | TeamsReply, Field(discriminator="type")]


class Scenario(StrictModel):
    schemaVersion: Literal["1.0"]
    scenarioId: Key
    title: Annotated[str, Field(min_length=1, max_length=200)]
    description: Annotated[str, Field(max_length=2000)] = ""
    author: Annotated[str, Field(min_length=1, max_length=100)]
    createdAt: datetime
    tenantAssumptions: Annotated[list[str], Field(min_length=1, max_length=20)]
    requiredUsers: Annotated[list[Key], Field(min_length=1, max_length=5)]
    requiredChannels: Annotated[list[Key], Field(max_length=20)] = Field(default_factory=list)
    dryRun: bool = True
    metadata: dict[str, Annotated[str, Field(max_length=200)]] = Field(default_factory=dict)
    tags: Annotated[list[str], Field(max_length=20)] = Field(default_factory=list)
    activities: Annotated[list[Activity], Field(min_length=1, max_length=200)]

    @model_validator(mode="after")
    def consistent(self) -> Self:
        if self.createdAt.tzinfo is None:
            raise ValueError("createdAt must include a timezone")
        seen: dict[str, Activity] = {}
        if len(set(self.requiredUsers)) != len(self.requiredUsers):
            raise ValueError("requiredUsers must be unique")
        if len(set(self.requiredChannels)) != len(self.requiredChannels):
            raise ValueError("requiredChannels must be unique")
        for action in self.activities:
            if action.id in seen:
                raise ValueError("Duplicate activity ID")
            if action.user not in self.requiredUsers:
                raise ValueError("Activity user must be in requiredUsers")
            if len(set(action.dependsOn)) != len(action.dependsOn):
                raise ValueError("Duplicate dependency")
            if any(dep not in seen for dep in action.dependsOn):
                raise ValueError("Dependencies must refer to earlier activities (no cycles)")
            if isinstance(action, TeamsMessage | TeamsReply):
                if action.channel not in self.requiredChannels:
                    raise ValueError("Channel must be in requiredChannels")
            if isinstance(action, TeamsReply):
                parent = seen.get(action.parent)
                if not isinstance(parent, TeamsMessage) or parent.channel != action.channel:
                    raise ValueError("Reply requires an earlier root message in the same channel")
                if action.parent not in action.dependsOn:
                    raise ValueError("Reply must depend on its parent")
            seen[action.id] = action
        return self


PLACEHOLDER = re.compile(r"\{\{user\.([a-z][a-z0-9_-]*)\.(displayName|userPrincipalName)\}\}")
