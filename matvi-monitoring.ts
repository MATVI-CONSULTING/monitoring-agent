import { TerraformStack, Fn, S3Backend } from "cdktf";
import { Construct } from "constructs";
import { InfraCdkConfig } from "../config/config.interface";
import { 
  CDK_ENVIRONMENT, 
  CDK_PREFIX_STACK, 
  MATVI_MONITORING_PASSWORD, 
  MATVI_MONITORING_USERNAME, 
  OVH_APPLICATION_KEY, 
  OVH_APPLICATION_SECRET, 
  OVH_CONSUMER_KEY, 
  S3_ACCESS_KEY_ID,
  S3_SECRET_ACCESS_KEY
} from "../config/env";
import { provider, release } from '../../.gen/providers/helm';
import * as k8s from "../../.gen/providers/kubernetes";
import * as path from "path";
import { OvhProvider } from "../../.gen/providers/ovh/provider";
import { CloudProjectKube } from "../../.gen/providers/ovh/cloud-project-kube";

export class MatviMonitoringAgent extends TerraformStack {
  constructor(
    scope: Construct,
    private readonly stackPrefix: string,
    private readonly config: InfraCdkConfig,
    private readonly kubernetesCluster: CloudProjectKube
  ) {
    super(scope, stackPrefix);
    this.deployProviders();

    if(this.config.monitoring.matviMonitoring.enabled){
      this.deploy();
    }
  }

  private deployProviders(): void {
    new OvhProvider(this, `${this.stackPrefix}-ovh`, {
      endpoint: this.config.provider.ovh.endpoint,
      applicationKey: OVH_APPLICATION_KEY,
      applicationSecret: OVH_APPLICATION_SECRET,
      consumerKey: OVH_CONSUMER_KEY,
    });

    // Store Terraform configuration on S3
    new S3Backend(this, {
      bucket: this.config.tfState.bucket,
      key: `${CDK_PREFIX_STACK}-${CDK_ENVIRONMENT}/${this.stackPrefix}.tfstate`,
      region: this.config.tfState.region,
      endpoints: { s3: this.config.tfState.endpoint},
      usePathStyle: true,
      accessKey: S3_ACCESS_KEY_ID,
      secretKey: S3_SECRET_ACCESS_KEY,
      skipCredentialsValidation: true,
      skipRegionValidation: true,
      skipRequestingAccountId: true,
      skipS3Checksum: true
    });

    new k8s.provider.KubernetesProvider(this, `${this.stackPrefix}-k8s-provider`, {
      host: this.kubernetesCluster.kubeconfigAttributes.get(0).host,
      clientCertificate: Fn.base64decode(this.kubernetesCluster.kubeconfigAttributes.get(0).clientCertificate),
      clientKey: Fn.base64decode(this.kubernetesCluster.kubeconfigAttributes.get(0).clientKey),
      clusterCaCertificate: Fn.base64decode(this.kubernetesCluster.kubeconfigAttributes.get(0).clusterCaCertificate),
    });

    new provider.HelmProvider(this, `${this.stackPrefix}-helm-provider`, {
      kubernetes: {
        host: this.kubernetesCluster.kubeconfigAttributes.get(0).host,
        clientCertificate: Fn.base64decode(this.kubernetesCluster.kubeconfigAttributes.get(0).clientCertificate),
        clientKey: Fn.base64decode(this.kubernetesCluster.kubeconfigAttributes.get(0).clientKey),
        clusterCaCertificate: Fn.base64decode(this.kubernetesCluster.kubeconfigAttributes.get(0).clusterCaCertificate),
      }
    });
  }

  private deploy(): void {
    new release.Release(this, `${this.stackPrefix}-matvi-monitoring-agent`, {
      name: `matvi-monitoring-agent`,
      chart: `${path.resolve(__dirname)}/chart`,
      version: "0.1.4",
      namespace: this.config.monitoring.namespace.name,
      values: [Fn.templatefile(`${path.resolve(__dirname)}/chart/values.yaml`, {})],
      set: [
        {
          name: "agent.labels.cluster",
          value: this.kubernetesCluster.name
        },
        { 
          name: "agent.labels.env",
          value: CDK_ENVIRONMENT
        },
        { 
          name: "agent.labels.client",
          value: this.config.monitoring.matviMonitoring.client
        },
        { 
          name: "agent.basicAuth.username",
          value: MATVI_MONITORING_USERNAME
        },
        { 
          name: "agent.basicAuth.password",
          value: MATVI_MONITORING_PASSWORD
        },
      ],
      wait: true,
    });
  }
}
