
How Kiro's Model Context Protocol (MCP) Handles Repository Access

The Model Context Protocol (MCP) functions as an open standard API client inside Kiro, decoupling the LLM agent from how it fetches remote data. When dealing with repository access across remote environments like OpenShift Dev Workspaces, Kiro handles it through a layered execution architecture:

1. Configuration Levels & Hot-Reloading

Kiro manages repository tools via an mcp.json file. This file can be defined at two different granularities, which automatically merge on runtime:
• Global (~/.kiro/settings/mcp.json): Holds platform-wide tools, like an enterprise GitHub or GitLab MCP server setup that applies to all your projects.
• Workspace (.kiro/settings/mcp.json): Committed directly inside your specific repository to activate project-specific context and local environment hooks.

2. Local vs. Remote Repository Access

When Kiro is connected over SSH to your OpenShift Dev Space, the agent can interact with repositories in two distinct ways:
• Internal (Via Stdio/SSH Transport): If an MCP Git server runs directly inside the remote OpenShift workspace container, Kiro passes commands down through the active SSH session using the standard input/output (stdio) transport protocol. The agent can read local git histories, branches, and diffs within the remote workspace filesystem dynamically.
• External (Via HTTP/OAuth Protocol): For interacting directly with hosting platforms (e.g., pulling issues, checking PRs, triggering webhooks on GitHub or AWS CodeCommit), Kiro utilizes an HTTP transport layer. It natively supports Dynamic Client Registration (DCR) and OAuth scopes to safely authenticate your developer identity securely from your local desktop out to the web.

3. Sample MCP Workspace Integration

Below is an example of an .kiro/settings/mcp.json configuration mapping an external GitHub repository server and a localized system tool:
json
{
  "mcpServers": {
    "github-repo-manager": {
      "command": "npx",
      "args": ["-y", "@modelcontextprotocol/server-github"],
      "transport": "stdio",
      "env": {
        "GITHUB_PERSONAL_ACCESS_TOKEN": "${ENV_GITHUB_TOKEN}"
      },
      "autoApprove": [
        "get_file_contents",
        "search_repositories"
      ]
    }
  }
}
Use code with caution.
