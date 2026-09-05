package org.mayabanque.wero.consumer;

import jakarta.ws.rs.*;
import jakarta.ws.rs.core.MediaType;
import org.eclipse.microprofile.rest.client.inject.RegisterRestClient;

@Path("/wero/payments")
@RegisterRestClient(configKey="mock-wero")
@Consumes(MediaType.APPLICATION_JSON)
@Produces(MediaType.APPLICATION_JSON)
public interface WeroClient {
    @POST
    ConsumerPaymentResource.PaymentResponse forward(@HeaderParam("X-Correlation-Id") String correlationId,
                                                    ConsumerPaymentResource.PaymentRequest request);
}
