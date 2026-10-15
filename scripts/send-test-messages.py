#!/usr/bin/env python3
"""
Send N test messages to a Service Bus queue or topic using Entra ID auth via
DefaultAzureCredential - no connection string involved, consistent with the
least-privilege posture described in ../README.md.

The identity running this script (your `az login` user, or a CI service
principal via OIDC) needs its own scoped role assignment for this - e.g.
"Azure Service Bus Data Sender" on the same queue/topic - separate from, and in
addition to, the receiver role granted to the consumer workload's identity
in terraform/servicebus-tenant. Grant it only for the duration of testing if using a
throwaway/CI identity.

Usage:
    python3 send-test-messages.py \
        --namespace-fqdn myns.servicebus.windows.net \
        --queue-name q-app-1234-uc01-orders \
        --count 20

    python3 send-test-messages.py \
        --namespace-fqdn sb-example-shared.servicebus.windows.net \
        --topic-name t-app-5678-uc02-events \
        --count 20
"""
import argparse
import sys

from azure.identity import DefaultAzureCredential
from azure.servicebus import ServiceBusClient, ServiceBusMessage


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--namespace-fqdn", required=True,
                         help="e.g. myns.servicebus.windows.net")
    target = parser.add_mutually_exclusive_group(required=True)
    target.add_argument("--queue-name")
    target.add_argument("--topic-name")
    parser.add_argument("--count", type=int, default=10,
                         help="Number of test messages to send")
    parser.add_argument("--body-prefix", default="keda-verify",
                         help="Prefix used in each message body")
    args = parser.parse_args()

    credential = DefaultAzureCredential()
    client = ServiceBusClient(
        fully_qualified_namespace=args.namespace_fqdn,
        credential=credential,
    )

    with client:
        if args.queue_name:
            sender = client.get_queue_sender(queue_name=args.queue_name)
        else:
            sender = client.get_topic_sender(topic_name=args.topic_name)
        with sender:
            messages = [
                ServiceBusMessage(f"{args.body_prefix}-{i}")
                for i in range(args.count)
            ]
            sender.send_messages(messages)

    print(f"Sent {args.count} messages to {args.queue_name or args.topic_name}@{args.namespace_fqdn}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
