#!/usr/bin/env python3
from flask import Flask, request, jsonify
import json
import threading
import time

app = Flask(__name__)

# Store received webhooks for verification
received_webhooks = []
webhook_lock = threading.Lock()

@app.route('/webhook', methods=['POST'])
def webhook():
    webhook_data = {
        'timestamp': time.time(),
        'headers': dict(request.headers),
        'body': request.get_data().decode(),
        'json': request.get_json() if request.is_json else None,
        'method': request.method,
        'url': request.url
    }
    
    with webhook_lock:
        received_webhooks.append(webhook_data)
    
    print(f"[WEBHOOK {len(received_webhooks)}] Received:")
    print(json.dumps(webhook_data, indent=2))
    print("-" * 50)
    
    return jsonify({
        "status": "received", 
        "webhook_id": len(received_webhooks),
        "timestamp": webhook_data['timestamp']
    }), 200

@app.route('/webhooks', methods=['GET'])
def get_webhooks():
    """Endpoint to check received webhooks"""
    with webhook_lock:
        return jsonify({
            "webhooks": received_webhooks, 
            "count": len(received_webhooks)
        })

@app.route('/webhooks/latest', methods=['GET'])
def get_latest_webhook():
    """Get the most recent webhook"""
    with webhook_lock:
        if received_webhooks:
            return jsonify({
                "webhook": received_webhooks[-1],
                "count": len(received_webhooks)
            })
        else:
            return jsonify({"webhook": None, "count": 0}), 404

@app.route('/reset', methods=['POST'])
def reset():
    """Reset webhook storage"""
    with webhook_lock:
        received_webhooks.clear()
    print("[RESET] Webhook storage cleared")
    return jsonify({"status": "reset", "count": 0})

@app.route('/health', methods=['GET'])
def health():
    """Health check endpoint"""
    return jsonify({
        "status": "healthy",
        "webhook_count": len(received_webhooks)
    })

if __name__ == '__main__':
    print("🚀 Starting webhook server on http://localhost:8080")
    print("📡 Webhook endpoint: POST /webhook")
    print("📊 Status endpoint: GET /webhooks")
    print("🔄 Reset endpoint: POST /reset")
    print("-" * 50)
    
    app.run(host='0.0.0.0', port=9090, debug=False, threaded=True)
