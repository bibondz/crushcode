# Crushcode Plugin Example - Python

This is a sample plugin implementation in Python that demonstrates how to create external tools for Crushcode.

## JSON-RPC 2.0 Implementation

The plugin communicates with Crushcore via stdin/stdout using JSON-RPC 2.0 protocol.

```python
#!/usr/bin/env python3
import json
import sys
from typing import Dict, Any

class CrushcodePlugin:
    def __init__(self):
        self.name = "python-example-plugin"
        self.version = "1.0.0"
        self.capabilities = {
            "tools": [
                {
                    "name": "execute_python",
                    "description": "Execute Python code safely",
                    "parameters": {
                        "type": "object",
                        "properties": {
                            "code": {
                                "type": "string",
                                "description": "Python code to execute"
                            }
                        },
                        "required": ["code"]
                    }
                }
            ]
        }
    
    def handle_request(self, request: Dict[str, Any]) -> Dict[str, Any]:
        """Handle JSON-RPC 2.0 requests"""
        if "method" not in request:
            return {
                "jsonrpc": "2.0",
                "id": request.get("id"),
                "error": {
                    "code": -32600,
                    "message": "Invalid Request"
                }
            }
        
        method = request["method"]
        params = request.get("params", {})
        request_id = request.get("id")
        
        try:
            if method == "initialize":
                return self._initialize(request_id)
            elif method == "execute":
                return self._execute(request_id, params)
            elif method == "health_check":
                return self._health_check(request_id)
            else:
                return {
                    "jsonrpc": "2.0",
                    "id": request_id,
                    "error": {
                        "code": -32601,
                        "message": "Method not found"
                    }
                }
        except Exception as e:
            return {
                "jsonrpc": "2.0",
                "id": request_id,
                "error": {
                    "code": -32603,
                    "message": f"Internal error: {str(e)}"
                }
            }
    
    def _initialize(self, request_id: Any) -> Dict[str, Any]:
        """Initialize plugin"""
        return {
            "jsonrpc": "2.0",
            "id": request_id,
            "result": {
                "name": self.name,
                "version": self.version,
                "capabilities": self.capabilities
            }
        }
    
    def _execute(self, request_id: Any, params: Dict[str, Any]) -> Dict[str, Any]:
        """Execute plugin functionality"""
        tool = params.get("tool")
        arguments = params.get("arguments", {})
        
        if tool == "execute_python":
            code = arguments.get("code", "")
            try:
                # Execute Python code in a safe context
                result = eval(code, {"__builtins__": {}}, {})
                return {
                    "jsonrpc": "2.0",
                    "id": request_id,
                    "result": {
                        "success": True,
                        "output": str(result)
                    }
                }
            except Exception as e:
                return {
                    "jsonrpc": "2.0",
                    "id": request_id,
                    "result": {
                        "success": False,
                        "error": str(e)
                    }
                }
        else:
            return {
                "jsonrpc": "2.0",
                "id": request_id,
                "error": {
                    "code": -32602,
                    "message": f"Unknown tool: {tool}"
                }
            }
    
    def _health_check(self, request_id: Any) -> Dict[str, Any]:
        """Check plugin health"""
        return {
            "jsonrpc": "2.0",
            "id": request_id,
            "result": {
                "status": "healthy",
                "uptime": "0s"
            }
        }
    
    def run(self):
        """Main plugin loop"""
        print("Crushcode Plugin - Python Example", file=sys.stderr)
        print(f"Plugin: {self.name} v{self.version}", file=sys.stderr)
        
        try:
            for line in sys.stdin:
                if line.strip():
                    request = json.loads(line)
                    response = self.handle_request(request)
                    print(json.dumps(response), flush=True)
        except KeyboardInterrupt:
            pass
        except Exception as e:
            print(f"Plugin error: {e}", file=sys.stderr)

if __name__ == "__main__":
    plugin = CrushcodePlugin()
    plugin.run()
```

## Usage

1. Save the plugin as `python_plugin.py`
2. Make it executable: `chmod +x python_plugin.py`
3. Add to Crushcode configuration:

```toml
[plugins.python_example]
path = "/path/to/python_plugin.py"
enabled = true
```

## Testing

Test the plugin directly:

```bash
# Initialize
echo '{"jsonrpc":"2.0","id":1,"method":"initialize"}' | python3 python_plugin.py

# Execute tool
echo '{"jsonrpc":"2.0","id":2,"method":"execute","params":{"tool":"execute_python","arguments":{"code":"2 + 2"}}}' | python3 python_plugin.py

# Health check
echo '{"jsonrpc":"2.0","id":3,"method":"health_check"}' | python3 python_plugin.py
```

## Best Practices

1. **Error Handling**: Always return valid JSON-RPC 2.0 responses
2. **Input Validation**: Validate all parameters before processing
3. **Security**: Use safe execution contexts for dynamic code
4. **Logging**: Use stderr for logging, stdout for JSON-RPC
5. **Resource Management**: Clean up resources on exit