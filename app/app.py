import json
import requests
from flask import Flask, request, Response
from urllib.parse import urlparse

# Carrega a configuração do mapeamento ao iniciar
with open('config.json') as f:
    config = json.load(f)

# Garante que estamos usando o mapa de URLs correto
USER_MAP = config.get('user_to_backend_url_mapping', {})

app = Flask(__name__)

@app.route('/', defaults={'path': ''}, methods=['GET', 'POST', 'PUT', 'DELETE', 'PATCH', 'OPTIONS'])
@app.route('/<path:path>', methods=['GET', 'POST', 'PUT', 'DELETE', 'PATCH', 'OPTIONS'])
def proxy(path):
    user_email = request.headers.get('X-Goog-Authenticated-User-Email', '').replace('accounts.google.com:', '')
    
    if not user_email:
        return "Acesso Negado: Identidade IAP não encontrada.", 403

    backend_base_url = USER_MAP.get(user_email)
    
    if not backend_base_url:
        return f"Acesso Negado: Usuário '{user_email}' não possui um mapeamento de URL.", 403

    # Lógica de URL simples: anexa o caminho da requisição à URL base do backend
    destination_url = backend_base_url.rstrip('/') + '/' + path.lstrip('/')
    
    try:
        # Prepara os cabeçalhos, garantindo que o 'Host' header seja o do backend
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

        # Prepara os cabeçalhos da resposta, limpando apenas o essencial
        response_headers = {}
        for key, value in resp.headers.items():
            if key.lower() not in ['transfer-encoding', 'connection']:
                response_headers[key] = value

        # Retorna a resposta do backend diretamente para o navegador, sem reescrita
        return Response(resp.iter_content(chunk_size=8192), resp.status_code, response_headers)

    except requests.exceptions.RequestException as e:
        return f"Erro ao contatar o serviço de backend (VitaCare): {e}", 502

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=8080)