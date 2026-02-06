#!/usr/bin/env python3
"""
Vault Unsealer for Kubernetes
Tool unseal Vault pods in Kubernetes cluster
"""

import os
import sys
import time
import json
import logging
import argparse
from typing import List, Dict, Optional
from dataclasses import dataclass
import requests
from requests.adapters import HTTPAdapter
from urllib3.util.retry import Retry

# Setup logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(levelname)s - %(message)s',
    datefmt='%Y-%m-%d %H:%M:%S'
)
logger = logging.getLogger('vault-k8s-unsealer')


@dataclass
class VaultPod:
    """Vault pod information"""
    name: str
    namespace: str
    ip: str
    service_name: str
    port: int = 8200


class KubernetesClient:
    """Kubernetes client interaction cluster"""
    
    def __init__(self, namespace: str):
        self.namespace = namespace
        self.api_url = "https://kubernetes.default.svc"
        self.token = self._load_token()
        self.ca_cert = "/var/run/secrets/kubernetes.io/serviceaccount/ca.crt"
        self.session = self._create_session()
    
    def _load_token(self) -> str:
        """Load service account token"""
        token_path = "/var/run/secrets/kubernetes.io/serviceaccount/token"
        try:
            with open(token_path, 'r') as f:
                return f.read().strip()
        except FileNotFoundError:
            logger.warning("Running outside K8s cluster, using KUBECONFIG")
            return ""
    
    def _create_session(self) -> requests.Session:
        """Create requests session retry"""
        session = requests.Session()
        session.headers.update({
            'Authorization': f'Bearer {self.token}'
        })
        retry_strategy = Retry(
            total=3,
            backoff_factor=1,
            status_forcelist=[429, 500, 502, 503, 504]
        )
        adapter = HTTPAdapter(max_retries=retry_strategy)
        session.mount("https://", adapter)
        return session
    
    def get_vault_pods(self, label_selector: str = "app=vault") -> List[VaultPod]:
        """Lits Vault pods"""
        url = f"{self.api_url}/api/v1/namespaces/{self.namespace}/pods"
        params = {"labelSelector": label_selector}
        
        try:
            verify = self.ca_cert if os.path.exists(self.ca_cert) else False
            response = self.session.get(url, params=params, verify=verify, timeout=10)
            response.raise_for_status()
            data = response.json()
            
            pods = []
            for item in data.get('items', []):
                name = item['metadata']['name']
                pod_ip = item['status'].get('podIP')
                phase = item['status'].get('phase')
                
                # Lists pod running
                if phase == 'Running' and pod_ip:
                    pods.append(VaultPod(
                        name=name,
                        namespace=self.namespace,
                        ip=pod_ip,
                        service_name=f"{name}.vault-internal"
                    ))
            
            return pods
        except Exception as e:
            logger.error(f"Can't list pods: {e}")
            return []
    
    def get_statefulset_pods(self, statefulset_name: str) -> List[VaultPod]:
        """Lists pods from StatefulSet"""
        return self.get_vault_pods(f"app.kubernetes.io/name={statefulset_name}")


class VaultClient:
    """Client interaction Vault API"""
    
    def __init__(self, timeout: int = 10, verify_ssl: bool = False):
        self.timeout = timeout
        self.verify_ssl = verify_ssl
        self.session = self._create_session()
    
    def _create_session(self) -> requests.Session:
        """Create session with retry logic"""
        session = requests.Session()
        retry_strategy = Retry(
            total=3,
            backoff_factor=1,
            status_forcelist=[429, 500, 502, 503, 504],
            allowed_methods=["HEAD", "GET", "PUT", "POST"]
        )
        adapter = HTTPAdapter(max_retries=retry_strategy)
        session.mount("http://", adapter)
        session.mount("https://", adapter)
        return session
    
    def get_vault_url(self, pod: VaultPod, use_service: bool = False) -> str:
        """Create Vault URL from pod info"""
        if use_service:
            # Use service name to connect
            return f"http://{pod.service_name}.{pod.namespace}.svc.cluster.local:{pod.port}"
        else:
            # Use pod IP
            return f"http://{pod.ip}:{pod.port}"
    
    def get_seal_status(self, url: str) -> Optional[Dict]:
        """List seal status Vault"""
        try:
            response = self.session.get(
                f"{url}/v1/sys/seal-status",
                timeout=self.timeout,
                verify=self.verify_ssl
            )
            response.raise_for_status()
            return response.json()
        except requests.exceptions.RequestException as e:
            logger.debug(f"Can't list seal status from {url}: {e}")
            return None
    
    def unseal(self, url: str, key: str) -> Optional[Dict]:
        """Do unseal với one key"""
        try:
            payload = {"key": key}
            response = self.session.put(
                f"{url}/v1/sys/unseal",
                json=payload,
                timeout=self.timeout,
                verify=self.verify_ssl
            )
            response.raise_for_status()
            return response.json()
        except requests.exceptions.RequestException as e:
            logger.error(f"Error unseal {url}: {e}")
            return None
    
    def health_check(self, url: str) -> Dict:
        """Health check Vault"""
        try:
            response = self.session.get(
                f"{url}/v1/sys/health",
                timeout=self.timeout,
                verify=self.verify_ssl
            )
            return {
                'healthy': response.status_code in [200, 429, 473, 503],
                'initialized': response.status_code != 501,
                'sealed': response.status_code == 503,
                'standby': response.status_code == 429,
                'status_code': response.status_code
            }
        except Exception as e:
            return {
                'healthy': False,
                'initialized': False,
                'sealed': True,
                'standby': False,
                'status_code': 0,
                'error': str(e)
            }


class VaultUnsealer:
    """Main unsealer class"""
    
    def __init__(self, 
                 namespace: str,
                 unseal_keys: List[str],
                 label_selector: str = "app=vault",
                 use_service: bool = False,
                 timeout: int = 10):
        self.namespace = namespace
        self.unseal_keys = unseal_keys
        self.label_selector = label_selector
        self.use_service = use_service
        self.k8s_client = KubernetesClient(namespace)
        self.vault_client = VaultClient(timeout=timeout)
    
    def unseal_pod(self, pod: VaultPod) -> bool:
        """Unseal from Vault pod"""
        vault_url = self.vault_client.get_vault_url(pod, self.use_service)
        logger.info(f"[{pod.name}] Check seal status...")
        
        # Check seal status
        status = self.vault_client.get_seal_status(vault_url)
        if not status:
            logger.error(f"[{pod.name}] Can not connect to Vault")
            return False
        
        # If unsealed then skip
        if not status.get('sealed'):
            logger.info(f"[{pod.name}] ✓ Unsealed")
            return True
        
        # Info seal threshold
        threshold = status.get('t', 0)
        progress = status.get('progress', 0)
        logger.info(f"[{pod.name}] Sealed - need {threshold} keys, current: {progress}")
        
        # Unseal using each key
        for i, key in enumerate(self.unseal_keys, 1):
            logger.debug(f"[{pod.name}] Applied key {i}/{len(self.unseal_keys)}")
            
            result = self.vault_client.unseal(vault_url, key)
            if not result:
                logger.error(f"[{pod.name}] Unseal fail at key {i}")
                return False
            
            new_progress = result.get('progress', 0)
            logger.debug(f"[{pod.name}] Progress: {new_progress}/{threshold}")
            
            # Nếu unseal Success
            if not result.get('sealed'):
                logger.info(f"[{pod.name}] ✓ Unsealed success!")
                return True
            
            time.sleep(0.2)  # Small delay
        
        # Final check
        final_status = self.vault_client.get_seal_status(vault_url)
        if final_status and not final_status.get('sealed'):
            logger.info(f"[{pod.name}] ✓ Unsealed success!")
            return True
        
        logger.error(f"[{pod.name}] ✗ Don't enough keys to unseal")
        return False
    
    def unseal_all_pods(self) -> Dict[str, bool]:
        """Unseal all Vault pods"""
        logger.info(f"Find Vault pods in namespace '{self.namespace}'...")
        
        pods = self.k8s_client.get_vault_pods(self.label_selector)
        if not pods:
            logger.warning("Don't fine Vault any pods ")
            return {}
        
        logger.info(f"Find {len(pods)} Vault pods: {', '.join(p.name for p in pods)}")
        
        results = {}
        for pod in pods:
            try:
                results[pod.name] = self.unseal_pod(pod)
            except Exception as e:
                logger.error(f"[{pod.name}] Exception: {e}")
                results[pod.name] = False
        
        return results
    
    def watch_and_unseal(self, interval: int = 60):
        """Watch mode – automatically unseals when a sealed state is detected"""
        logger.info(f"Start watch mode – check every {interval}s")
        logger.info(" Ctrl+C stop")
        
        try:
            while True:
                logger.info("=" * 60)
                logger.info(f"Checked {time.strftime('%Y-%m-%d %H:%M:%S')}")
                
                results = self.unseal_all_pods()
                
                if results:
                    success = sum(1 for v in results.values() if v)
                    total = len(results)
                    logger.info(f"Result: {success}/{total} pods unsealed")
                    
                    # Log details
                    for pod_name, status in results.items():
                        status_str = "✓ OK" if status else "✗ FAILED"
                        logger.info(f"  [{pod_name}]: {status_str}")
                else:
                    logger.warning("No pods were processed")
                
                logger.info(f"Wait {interval}s before the next check...")
                time.sleep(interval)
                
        except KeyboardInterrupt:
            logger.info("\nStop watch mode")
    
    def health_check_all(self) -> Dict[str, Dict]:
        """Health all pods"""
        logger.info(f"Health check Vault pods in namespace '{self.namespace}'...")
        
        pods = self.k8s_client.get_vault_pods(self.label_selector)
        if not pods:
            logger.warning("No Vault pods found")
            return {}
        
        results = {}
        for pod in pods:
            vault_url = self.vault_client.get_vault_url(pod, self.use_service)
            health = self.vault_client.health_check(vault_url)
            results[pod.name] = health
            
            # Log status
            status_emoji = "✓" if health['healthy'] else "✗"
            sealed_str = "sealed" if health['sealed'] else "unsealed"
            logger.info(f"[{pod.name}] {status_emoji} {sealed_str} (code: {health['status_code']})")
        
        return results


def load_keys_from_env() -> List[str]:
    """Load unseal keys from environment variables"""
    keys = []
    
    # Thử load from VAULT_UNSEAL_KEYS (comma separated)
    keys_str = os.getenv('VAULT_UNSEAL_KEYS')
    if keys_str:
        keys = [k.strip() for k in keys_str.split(',') if k.strip()]
    
    # Try load from VAULT_UNSEAL_KEY_1, VAULT_UNSEAL_KEY_2, ...
    if not keys:
        i = 1
        while True:
            key = os.getenv(f'VAULT_UNSEAL_KEY_{i}')
            if not key:
                break
            keys.append(key)
            i += 1
    
    # Try load from UNSEAL_KEY_1, UNSEAL_KEY_2, ... (backward compatibility)
    if not keys:
        i = 1
        while True:
            key = os.getenv(f'UNSEAL_KEY_{i}')
            if not key:
                break
            keys.append(key)
            i += 1
    
    return keys


def main():
    parser = argparse.ArgumentParser(
        description='Vault Unsealer for Kubernetes',
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Environment Variables:
  VAULT_UNSEAL_KEYS         Comma-separated unseal keys
  VAULT_UNSEAL_KEY_1,2,3    Individual unseal keys
  VAULT_NAMESPACE           Kubernetes namespace (default: vault)
  VAULT_LABEL_SELECTOR      Pod label selector (default: app=vault)

Examples:
  # Unseal once
  %(prog)s --keys key1 key2 key3

  # Unseal using environment variables
  export VAULT_UNSEAL_KEYS="key1,key2,key3"
  %(prog)s

  # Watch mode
  %(prog)s --watch --interval 30

  # Health check only
  %(prog)s --health-check

  # Custom namespace and label
  %(prog)s --namespace vault-prod --label app.kubernetes.io/name=vault
        """
    )
    
    parser.add_argument(
        '--namespace', '-n',
        default=os.getenv('VAULT_NAMESPACE', 'vault'),
        help='Kubernetes namespace (default: vault or $VAULT_NAMESPACE)'
    )
    
    parser.add_argument(
        '--label', '-l',
        dest='label_selector',
        default=os.getenv('VAULT_LABEL_SELECTOR', 'app=vault'),
        help='Pod label selector (default: app=vault or $VAULT_LABEL_SELECTOR)'
    )
    
    parser.add_argument(
        '--keys', '-k',
        nargs='+',
        help='Unseal keys (or use env vars)'
    )
    
    parser.add_argument(
        '--watch', '-w',
        action='store_true',
        help='Watch mode - auto unseal when sealed'
    )
    
    parser.add_argument(
        '--interval', '-i',
        type=int,
        default=int(os.getenv('WATCH_INTERVAL', '60')),
        help='Watch interval in seconds (default: 60)'
    )
    
    parser.add_argument(
        '--health-check',
        action='store_true',
        help='Just check health status'
    )
    
    parser.add_argument(
        '--use-service',
        action='store_true',
        help='Use service name instead of pod IP'
    )
    
    parser.add_argument(
        '--timeout',
        type=int,
        default=10,
        help='Request timeout in seconds (default: 10)'
    )
    
    parser.add_argument(
        '--once',
        action='store_true',
        help='Run once and exit (useful for CronJobs)'
    )
    
    parser.add_argument(
        '--verbose', '-v',
        action='store_true',
        help='Verbose logging'
    )
    
    parser.add_argument(
        '--json',
        action='store_true',
        help='Output in JSON format'
    )
    
    args = parser.parse_args()
    
    # Setup logging
    if args.verbose:
        logger.setLevel(logging.DEBUG)
    
    if args.json:
        # Disable console logging use JSON output
        logger.handlers.clear()
    
    # Load unseal keys
    unseal_keys = args.keys or load_keys_from_env()
    
    if not unseal_keys and not args.health_check:
        logger.error("Dont't find unseal keys!")
        logger.error("Use --keys or set environment variables:")
        logger.error("  VAULT_UNSEAL_KEYS='key1,key2,key3'")
        logger.error("  or VAULT_UNSEAL_KEY_1='key1' VAULT_UNSEAL_KEY_2='key2' ...")
        sys.exit(1)
    
    # Create unsealer
    unsealer = VaultUnsealer(
        namespace=args.namespace,
        unseal_keys=unseal_keys,
        label_selector=args.label_selector,
        use_service=args.use_service,
        timeout=args.timeout
    )
    
    # Health check mode
    if args.health_check:
        results = unsealer.health_check_all()
        
        if args.json:
            print(json.dumps(results, indent=2))
        
        # Exit code: 0 if all healthy, 1 of ones pod unhealthy
        all_healthy = all(r.get('healthy', False) for r in results.values())
        sys.exit(0 if all_healthy else 1)
    
    # Watch mode
    if args.watch:
        unsealer.watch_and_unseal(args.interval)
        return
    
    # One-time unseal
    results = unsealer.unseal_all_pods()
    
    if args.json:
        output = {
            'timestamp': time.strftime('%Y-%m-%d %H:%M:%S'),
            'namespace': args.namespace,
            'total_pods': len(results),
            'successful': sum(1 for v in results.values() if v),
            'failed': sum(1 for v in results.values() if not v),
            'results': results
        }
        print(json.dumps(output, indent=2))
    else:
        # Summary
        success = sum(1 for v in results.values() if v)
        total = len(results)
        
        logger.info("=" * 60)
        logger.info(f"Result: {success}/{total} pods unsealed success")
        for name, status in results.items():
            status_str = "✓ SUCCESS" if status else "✗ FAILED"
            logger.info(f"  [{name}]: {status_str}")
    
    # Exit code
    all_success = all(results.values()) if results else False
    sys.exit(0 if all_success else 1)


if __name__ == '__main__':
    main()
