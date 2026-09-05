package org.mayabanque.wero.payment;

import jakarta.ws.rs.GET;
import jakarta.ws.rs.HeaderParam;
import jakarta.ws.rs.Path;
import jakarta.ws.rs.PathParam;
import jakarta.ws.rs.Produces;
import jakarta.ws.rs.core.MediaType;
import org.eclipse.microprofile.rest.client.inject.RegisterRestClient;

@Path("/sct-inst/transfers")
@RegisterRestClient(configKey = "sct-inst-status")
@Produces(MediaType.APPLICATION_JSON)
public interface SctInstStatusClient {
    @GET @Path("/{paymentId}")
    RailStatus get(@HeaderParam("X-Correlation-Id") String correlationId,
                   @PathParam("paymentId") String paymentId);
    record RailStatus(String paymentId, String status, String settlementId) {}
}
