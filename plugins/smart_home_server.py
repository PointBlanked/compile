# Example FastMCP plugin server (owner: Maxwell). Not run in CI.
#   pip install fastmcp
#   fastmcp run plugins/smart_home_server.py --transport http --port 8765
# Register in the app with MCPHTTPClient(endpoint: http://<host>:8765/mcp) and
# claims such as ["microwave_start": ToolClaim(textContains: ["start"])].
from fastmcp import FastMCP

mcp = FastMCP("echoguide-smart-home")


@mcp.tool
def microwave_start(text: str = "") -> str:
    """Start the paired smart microwave."""
    # Call the appliance vendor API here.
    return "Microwave started."


@mcp.tool
def notify_caregiver(region: str) -> str:
    """Tell the caregiver the user left a safe area."""
    # Send SMS / push via your provider here.
    return f"Carer told: left {region}."


if __name__ == "__main__":
    mcp.run(transport="http", port=8765)
