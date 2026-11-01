import { handle, type GatewayEnv } from './gateway';

export default {
  fetch(request: Request, env: GatewayEnv): Promise<Response> {
    return handle(request, env);
  },
};
