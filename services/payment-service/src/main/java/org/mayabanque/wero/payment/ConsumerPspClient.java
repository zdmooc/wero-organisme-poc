package org.mayabanque.wero.payment;

import jakarta.ws.rs.Consumes;
import jakarta.ws.rs.HeaderParam;
import jakarta.ws.rs.POST;
import jakarta.ws.rs.Path;
import jakarta.ws.rs.Produces;
import jakarta.ws.rs.core.MediaType;
import org.eclipse.microprofile.rest.client.inject.RegisterRestClient;

@Path("/consumer/payments")
@RegisterRestClient(configKey = "consumer-psp")
@Consumes(MediaType.APPLICATION_JSON)
@Produces(MediaType.APPLICATION_JSON)
public interface ConsumerPspClient {
    @POST
    PaymentResource.PaymentResponse pay(@HeaderParam("X-Correlation-Id") String correlationId,
                                        PaymentResource.PaymentRequest request);
}
