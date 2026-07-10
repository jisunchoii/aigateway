import foundry_codex_proxy as proxy


def test_make_server_binds_all_interfaces():
    server = proxy.make_server(port=0)
    try:
        assert server.server_address[0] == "0.0.0.0"
    finally:
        server.server_close()


def test_project_routes_use_ai_studio_token_scope():
    assert (
        proxy.mi_scope_for("https://aisproj-c0gvf2.services.ai.azure.com/api/projects/codexproj/openai/v1")
        == "https://ai.azure.com/.default"
    )
