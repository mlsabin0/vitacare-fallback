import json
import requests
from flask import Flask, request, Response
from urllib.parse import urlparse
import logging

# Configura o logging para imprimir na saída padrão
logging.basicConfig(level=logging.INFO)

# Carrega a configuração do mapeamento ao iniciar
with open('config.json') as f:
    config = json.load(f)

USER_MAP = config.get('user_to_backend_url_mapping', {})
FRONTEND_URL = config.get('frontend_base_url')

app = Flask(__name__)

@app.route('/', defaults={'path': ''}, methods=['GET', 'POST', 'PUT', 'DELETE', 'PATCH', 'OPTIONS'])
@app.route('/<path:path>', methods=['GET', 'POST', 'PUT', 'DELETE', 'PATCH', 'OPTIONS'])
def proxy(path):
    app.logger.info(f"--- NOVA REQUISIÇÃO PARA O CAMINHO: /{path} ---")
    user_email = request.headers.get('X-Goog-Authenticated-User-Email', '').replace('accounts.google.com:', '')
    
    if not user_email:
        app.logger.error("ERRO: Identidade IAP não encontrada.")
        return "Acesso Negado: Identidade IAP não encontrada.", 403
    app.logger.info(f"Usuário autenticado: {user_email}")

    backend_base_url = USER_MAP.get(user_email)
    
    if not backend_base_url:
        app.logger.error(f"ERRO: Usuário '{user_email}' não possui mapeamento.")
        return f"Acesso Negado: Usuário '{user_email}' não possui um mapeamento de URL.", 403

    destination_url = backend_base_url.rstrip('/') + '/' + path.lstrip('/')
    app.logger.info(f"Encaminhando requisição para: {destination_url}")
    
    try:
        backend_headers = {key: value for (key, value) in request.headers}
        backend_headers['Host'] = urlparse(backend_base_url).netloc

        resp = requests.request(
            method=request.method,
            url=destination_url,
            headers=backend_headers,
            data=request.get_data(),
            cookies=request.cookies,
            allow_redirects=False,
            stream=True)

        app.logger.info(f"Resposta do Backend: Status={resp.status_code}, Content-Type={resp.headers.get('Content-Type', 'N/A')}")

        response_headers = {}
        for key, value in resp.headers.items():
            if key.lower() not in ['transfer-encoding', 'connection']:
                response_headers[key] = value

        content_type = resp.headers.get('Content-Type', '').lower()
        rewriteable_types = ['text/html', 'text/css', 'application/javascript']
        
        if any(rewrite_type in content_type for rewrite_type in rewriteable_types):
            app.logger.info("Tipo de conteúdo reescrevível. Tentando reescrever o corpo...")
            backend_host_url = '/'.join(backend_base_url.split('/')[:3])
            original_body = resp.text
            new_body = original_body.replace(backend_host_url, FRONTEND_URL)
            app.logger.info(f"Tamanho do corpo original: {len(original_body)}, Tamanho do corpo novo: {len(new_body)}")
            
            response = Response(new_body, resp.status_code, response_headers)
            return response
        else:
            app.logger.info("Tipo de conteúdo não reescrevível (ex: imagem). Repassando diretamente.")
            return Response(resp.iter_content(chunk_size=8192), resp.status_code, response_headers)

    except requests.exceptions.RequestException as e:
        app.logger.error(f"ERRO CRÍTICO ao contatar o backend: {e}")
        return f"Erro ao contatar o serviço de backend (VitaCare): {e}", 502

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=8080)