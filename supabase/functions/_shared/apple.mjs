import { AppStoreServerAPIClient, SignedDataVerifier, Environment } from '@apple/app-store-server-library';
import { Buffer } from 'node:buffer';
import { HttpError, verifiedEntitlement } from './core.mjs';

export function appleService(env) {
  const required=name=>{const value=env.get(name);if(!value)throw new HttpError(503,'App Store verification is not configured yet.');return value;};
  const bundle=required('APP_BUNDLE_ID');
  const environment=env.get('APP_STORE_ENVIRONMENT')==='production' ? Environment.PRODUCTION : Environment.SANDBOX;
  const roots=required('APPLE_ROOT_CA_BASE64').split(',').map(value=>Buffer.from(value,'base64'));
  const appID=environment===Environment.PRODUCTION ? Number(required('APP_STORE_APP_ID')) : undefined;
  const verifier=new SignedDataVerifier(roots,true,environment,bundle,appID);
  const client=new AppStoreServerAPIClient(required('APP_STORE_PRIVATE_KEY').replace(/\\n/g,'\n'),required('APP_STORE_KEY_ID'),required('APP_STORE_ISSUER_ID'),bundle,environment);
  return {
    async transaction(id,householdID) {
      if(typeof id!=='string' || !/^\d{1,32}$/.test(id)) throw new HttpError(400,'Invalid App Store transaction.');
      const result=await client.getTransactionInfo(id);
      if(!result.signedTransactionInfo) throw new HttpError(400,'No signed App Store transaction.');
      const transaction=await verifier.verifyAndDecodeTransaction(result.signedTransactionInfo);
      return verifiedEntitlement(transaction,householdID,bundle);
    },
    async notification(signedPayload) {
      if(typeof signedPayload!=='string' || signedPayload.length>60000) throw new HttpError(400,'Invalid App Store notification.');
      const notification=await verifier.verifyAndDecodeNotification(signedPayload);
      if(!notification.data?.signedTransactionInfo) return null;
      const transaction=await verifier.verifyAndDecodeTransaction(notification.data.signedTransactionInfo);
      return verifiedEntitlement(transaction,transaction.appAccountToken,bundle);
    },
  };
}
