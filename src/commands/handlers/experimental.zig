// Re-export shim — all handlers split into domain-specific files.
// This file preserves the existing import path so callers (handlers.zig, build.zig)
// continue to work without changes.

const agent_loop_handler = @import("agent_loop_handler");
const workflow_handler = @import("workflow_handler");
const knowledge_handler = @import("knowledge_handler");
const team_handler = @import("team_handler");
const memory_handler = @import("memory_handler");

pub const handleGraph = agent_loop_handler.handleGraph;
pub const handleAutopilot = agent_loop_handler.handleAutopilot;
pub const handleCrush = agent_loop_handler.handleCrush;
pub const handleAgentLoop = agent_loop_handler.handleAgentLoop;

pub const handleWorkflow = workflow_handler.handleWorkflow;
pub const handlePhaseRun = workflow_handler.handlePhaseRun;
pub const handleCompact = workflow_handler.handleCompact;
pub const handleScaffold = workflow_handler.handleScaffold;

pub const handleKnowledge = knowledge_handler.handleKnowledge;
pub const handleWorker = knowledge_handler.handleWorker;
pub const handleHooks = knowledge_handler.handleHooks;

pub const handleSkillsResolve = team_handler.handleSkillsResolve;
pub const handleSkillsScan = team_handler.handleSkillsScan;
pub const handleTeam = team_handler.handleTeam;
pub const handleBackground = team_handler.handleBackground;

pub const handleMemory = memory_handler.handleMemory;
pub const handlePipeline = memory_handler.handlePipeline;
pub const handleThink = memory_handler.handleThink;
pub const handleSkillSync = memory_handler.handleSkillSync;
pub const handleTemplate = memory_handler.handleTemplate;
pub const handlePreview = memory_handler.handlePreview;
pub const handleDetect = memory_handler.handleDetect;
