(() => {
  const toolName = "system-mcp-kusto_kusto_query";
  const endpoint = "/api/kusto/query";
  const storageKey = "finops-hub-live-report-state";
  const calls = [];

  window.__sreagentLocal = { calls, endpoint, toolName };
  window.sreagent = {
    async callTool(name, args) {
      const call = {
        name,
        startedAt: new Date().toISOString(),
      };

      try {
        const response = await fetch(endpoint, {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({ name, args }),
        });
        const payload = await response.json().catch(() => null);

        if (!response.ok) {
          throw new Error(
            payload && payload.error
              ? payload.error
              : `Local Kusto bridge failed with HTTP ${response.status}.`,
          );
        }

        calls.push({
          ...call,
          completedAt: new Date().toISOString(),
          ok: true,
        });
        return payload;
      } catch (error) {
        calls.push({
          ...call,
          completedAt: new Date().toISOString(),
          error: error instanceof Error ? error.message : String(error),
          ok: false,
        });
        throw error;
      }
    },

    getState() {
      try {
        return JSON.parse(localStorage.getItem(storageKey) || "{}");
      } catch {
        return {};
      }
    },

    setState(state) {
      localStorage.setItem(storageKey, JSON.stringify(state || {}));
    },
  };
})();
